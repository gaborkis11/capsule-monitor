#!/usr/bin/env python3
"""Capsule System Monitor - data sampler for the Omarchy bar widget.

A port of providers.js from the Cinnamon applet. One long-running process,
started by the widget, printing one JSON object per line on stdout:

    fast cycle (default 1 s): cpu, mem, swp, tmp, net
    gpu cycle  (default 5 s): gpu (VRAM), gfx (GPU load)  - nvidia-smi or amdgpu sysfs
    disk cycle (60 s, fixed): ssd + the list of fixed volumes for the tooltip

Only raw numbers leave this module; thresholds, formatting and colours are the
widget's job. Every value is a number or null, never NaN.
"""

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import time

CPU_AVG_WINDOW = 10.0
CPU_TEMP_CHIPS = ["k10temp", "coretemp", "zenpower"]
HWMON_DIR = "/sys/class/hwmon"
TEMP_RESCAN = 30.0

NET_BARS = 20
NET_BUCKET = 1.0
# Bars are scaled to the peak of exactly the window that is on screen.
NET_PEAK_WINDOW = NET_BARS * NET_BUCKET
# Each direction has its own peak with this floor (512 KB/s): below it nothing
# is magnified, because that is idle noise or the ACK traffic of the other way.
NET_PEAK_FLOOR = 512 * 1024
NET_DEVLIST_TTL = 10.0
NET_SYSFS = "/sys/class/net"

PSEUDO_FSTYPES = {"tmpfs", "devtmpfs", "squashfs", "efivarfs"}
REMOVABLE_PREFIXES = ("/media/", "/run/media/", "/mnt/")
DISK_INTERVAL = 60.0

NVIDIA_ARGV = [
    "nvidia-smi", "--id=0",
    "--query-gpu=memory.used,memory.total,utilization.gpu,temperature.gpu",
    "--format=csv,noheader,nounits",
]
MIB = 1024 * 1024


def read_text(path):
    try:
        with open(path, "r") as f:
            return f.read()
    except OSError:
        return None


def read_number(path):
    text = read_text(path)
    if text is None:
        return None
    try:
        value = float(text.strip())
    except ValueError:
        return None
    return value if math.isfinite(value) else None


def num(value):
    return value if isinstance(value, (int, float)) and math.isfinite(value) else None


def rnd(value, decimals):
    value = num(value)
    return None if value is None else round(value, decimals)


def clamp(value, low, high):
    return low if value < low else high if value > high else value


def unescape_mount(field):
    out, i = [], 0
    while i < len(field):
        if field[i] == "\\" and i + 3 < len(field) and field[i + 1:i + 4].isdigit():
            out.append(chr(int(field[i + 1:i + 4], 8)))
            i += 4
        else:
            out.append(field[i])
            i += 1
    return "".join(out)


class Sampler:
    def __init__(self, disk_mount, gpu_enabled):
        self.disk_mount = disk_mount or "/"
        self.gpu_enabled = gpu_enabled
        self.values = {k: None for k in ("mem", "swp", "cpu", "gpu", "gfx", "tmp", "ssd", "net")}
        self.mounts = []

        self.cpu_last = self._read_cpu()
        self.cpu_history = []

        self.temp_path = self._find_temp()
        self.temp_scan = time.monotonic()

        self.net_devices = []
        self.net_dev_stamp = -1e9
        self.net_counters = {}
        self.net_samples = []
        self._refresh_net_devices(time.monotonic(), force=True)
        self._read_net_counters()
        self.net_stamp = time.monotonic()

        self.nvidia = shutil.which("nvidia-smi") if gpu_enabled else None
        self.nvidia_failures = 0
        self.gpu_proc = None
        self.amd_card = self._find_amd_card() if gpu_enabled else None

        self.sample_disk()

    # ------------------------------------------------------------------ CPU

    def _read_cpu(self):
        text = read_text("/proc/stat")
        if not text:
            return None
        parts = text.split("\n", 1)[0].split()
        if not parts or parts[0] != "cpu":
            return None
        fields = [int(x) for x in parts[1:9]]
        while len(fields) < 8:
            fields.append(0)
        # user nice system idle iowait irq softirq steal
        return {"total": sum(fields), "idle": fields[3], "iowait": fields[4]}

    def _sample_cpu(self, now):
        current = self._read_cpu()
        previous = self.cpu_last
        if current is None or previous is None:
            self.cpu_last = current
            self.values["cpu"] = None
            return
        self.cpu_last = current
        delta_total = current["total"] - previous["total"]
        if delta_total <= 0:
            return
        # Waiting for I/O is not the processor doing work: iowait counts as idle.
        delta_idle = (current["idle"] - previous["idle"]) + (current["iowait"] - previous["iowait"])
        pct = clamp(100.0 * (1 - delta_idle / delta_total), 0.0, 100.0)
        self.cpu_history.append((now, pct))
        while self.cpu_history and now - self.cpu_history[0][0] > CPU_AVG_WINDOW:
            self.cpu_history.pop(0)
        avg = sum(p for _, p in self.cpu_history) / len(self.cpu_history)
        self.values["cpu"] = {"pct": rnd(pct, 1), "avg10": rnd(avg, 1)}

    # ------------------------------------------------------- memory and swap

    def _sample_mem(self):
        text = read_text("/proc/meminfo")
        if not text:
            self.values["mem"] = self.values["swp"] = None
            return
        info = {}
        for line in text.splitlines():
            key, _, rest = line.partition(":")
            parts = rest.split()
            if parts:
                try:
                    info[key] = int(parts[0]) * 1024
                except ValueError:
                    pass
        total = info.get("MemTotal", 0)
        if total > 0:
            # Really used memory, like `free`: the page cache, buffers and
            # reclaimable slab are not counted.
            used = total - info.get("MemFree", 0) - info.get("Buffers", 0) \
                - info.get("Cached", 0) - info.get("SReclaimable", 0)
            used = max(0, used)
            self.values["mem"] = {
                "pct": rnd(clamp(100.0 * used / total, 0, 100), 1),
                "usedBytes": used, "totalBytes": total,
            }
        else:
            self.values["mem"] = None
        swap_total = info.get("SwapTotal", 0)
        swap_used = max(0, swap_total - info.get("SwapFree", 0)) if swap_total > 0 else 0
        # A machine without swap is at 0 %, not unknown.
        self.values["swp"] = {
            "pct": rnd(clamp(100.0 * swap_used / swap_total, 0, 100), 1) if swap_total > 0 else 0,
            "usedBytes": swap_used, "totalBytes": swap_total,
        }

    # ------------------------------------------------------------ temperature

    def _find_temp(self):
        best, best_rank = None, len(CPU_TEMP_CHIPS)
        try:
            entries = os.listdir(HWMON_DIR)
        except OSError:
            return None
        for entry in entries:
            base = os.path.join(HWMON_DIR, entry)
            name = read_text(base + "/name")
            if name is None:
                continue
            name = name.strip()
            if name not in CPU_TEMP_CHIPS:
                continue
            rank = CPU_TEMP_CHIPS.index(name)
            if rank >= best_rank:
                continue
            path = base + "/temp1_input"
            if read_number(path) is None:
                continue
            best, best_rank = path, rank
        return best

    def _sample_temp(self, now):
        if not self.temp_path and now - self.temp_scan >= TEMP_RESCAN:
            self.temp_scan = now
            self.temp_path = self._find_temp()
        if not self.temp_path:
            self.values["tmp"] = None
            return
        milli = read_number(self.temp_path)
        if milli is None:
            self.temp_path = None
            self.temp_scan = now - TEMP_RESCAN
            self.values["tmp"] = None
            return
        self.values["tmp"] = {"celsius": rnd(milli / 1000.0, 1)}

    # ---------------------------------------------------------------- network

    def _refresh_net_devices(self, now, force=False):
        if not force and now - self.net_dev_stamp < NET_DEVLIST_TTL:
            return
        self.net_dev_stamp = now
        try:
            devices = os.listdir(NET_SYSFS)
        except OSError:
            devices = []
        # Physical interfaces only (they have a "device" link in sysfs): every
        # byte that enters or leaves the machine crosses one exactly once, so
        # docker veth pairs, bridges and VPN tunnels are not counted twice.
        self.net_devices = [d for d in devices if os.path.exists(os.path.join(NET_SYSFS, d, "device"))]

    def _read_net_counters(self):
        down = up = 0
        counters = {}
        for dev in self.net_devices:
            base = os.path.join(NET_SYSFS, dev, "statistics")
            rx = read_number(base + "/rx_bytes")
            tx = read_number(base + "/tx_bytes")
            if rx is None or tx is None:
                continue
            counters[dev] = (rx, tx)
            prev = self.net_counters.get(dev)
            if prev:
                # A recreated interface restarts from zero: skip that step.
                if rx >= prev[0]:
                    down += rx - prev[0]
                if tx >= prev[1]:
                    up += tx - prev[1]
        self.net_counters = counters
        return down, up

    def _sample_net(self, now):
        self._refresh_net_devices(now)
        elapsed = now - self.net_stamp
        if elapsed < 0.001:
            return
        self.net_stamp = now
        down_bytes, up_bytes = self._read_net_counters()
        down = down_bytes / elapsed
        up = up_bytes / elapsed

        self.net_samples.append((now, down, up))
        while self.net_samples and now - self.net_samples[0][0] > NET_PEAK_WINDOW:
            self.net_samples.pop(0)

        # Each direction has its own peak and its own floor, on purpose: a
        # shared scale flattens an upload that follows a large download.
        peak_down = max([NET_PEAK_FLOOR] + [s[1] for s in self.net_samples])
        peak_up = max([NET_PEAK_FLOOR] + [s[2] for s in self.net_samples])
        hist_down, hist_up = self._net_history(now, peak_down, peak_up)
        self.values["net"] = {
            "downBps": round(down), "upBps": round(up), "totalBps": round(down + up),
            "peakDownBps": round(peak_down), "peakUpBps": round(peak_up),
            "historyDown": hist_down, "historyUp": hist_up,
        }

    def _net_history(self, now, peak_down, peak_up):
        down_sums = [0.0] * NET_BARS
        up_sums = [0.0] * NET_BARS
        counts = [0] * NET_BARS
        carry_down = carry_up = None
        for t, down, up in self.net_samples:
            age = max(0.0, now - t)
            index = NET_BARS - 1 - int(age // NET_BUCKET)
            if index < 0:
                carry_down, carry_up = down, up
                continue
            if index >= NET_BARS:
                continue
            down_sums[index] += down
            up_sums[index] += up
            counts[index] += 1
        out_down, out_up = [], []
        for i in range(NET_BARS):
            if counts[i] > 0:
                d = down_sums[i] / counts[i]
                u = up_sums[i] / counts[i]
                carry_down, carry_up = d, u
            else:
                d = carry_down or 0
                u = carry_up or 0
            out_down.append(round(clamp(d / peak_down, 0, 1), 3))
            out_up.append(round(clamp(u / peak_up, 0, 1), 3))
        return out_down, out_up

    # -------------------------------------------------------------------- GPU

    def _find_amd_card(self):
        try:
            cards = sorted(os.listdir("/sys/class/drm"))
        except OSError:
            return None
        best, best_total = None, 0
        for card in cards:
            if not card.startswith("card") or "-" in card:
                continue
            base = os.path.join("/sys/class/drm", card, "device")
            if (read_text(base + "/vendor") or "").strip() != "0x1002":
                continue
            total = read_number(base + "/mem_info_vram_total") or 0
            if total > best_total:
                best, best_total = base, total
        return best

    def sample_gpu(self):
        if not self.gpu_enabled:
            self.values["gpu"] = self.values["gfx"] = None
            return
        # Never stack a second nvidia-smi on a call still in flight.
        if self.gpu_proc is not None:
            return
        if self.nvidia and self.nvidia_failures < 3:
            try:
                self.gpu_proc = subprocess.Popen(
                    NVIDIA_ARGV, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                    stdin=subprocess.DEVNULL, text=True)
            except OSError:
                self.gpu_proc = None
                self.nvidia_failures += 1
            return
        if self.amd_card:
            self._sample_amd()
        else:
            self.values["gpu"] = self.values["gfx"] = None

    def poll_gpu(self):
        proc = self.gpu_proc
        if proc is None or proc.poll() is None:
            return
        self.gpu_proc = None
        output = proc.stdout.read() if proc.stdout else ""
        if proc.returncode != 0:
            self.nvidia_failures += 1
            if self.nvidia_failures >= 3 and self.amd_card:
                self._sample_amd()
            return
        self.nvidia_failures = 0
        parsed = self._parse_nvidia(output)
        if parsed:
            self.values["gpu"], self.values["gfx"] = parsed
        else:
            self.values["gpu"] = self.values["gfx"] = None

    def _parse_nvidia(self, text):
        for line in (text or "").splitlines():
            line = line.strip()
            if not line:
                continue
            fields = [f.strip() for f in line.split(",")]
            if len(fields) < 3:
                return None

            def f(i):
                try:
                    return num(float(fields[i]))
                except (ValueError, IndexError):
                    return None
            used, total, load, temp = f(0), f(1), f(2), f(3)
            gpu = None
            if used is not None and total:
                gpu = {"pct": rnd(clamp(100 * used / total, 0, 100), 1),
                       "usedMiB": round(used), "totalMiB": round(total), "celsius": rnd(temp, 1)}
            gfx = None if load is None else {"pct": rnd(clamp(load, 0, 100), 1)}
            return gpu, gfx
        return None

    def _sample_amd(self):
        base = self.amd_card
        used = read_number(base + "/mem_info_vram_used")
        total = read_number(base + "/mem_info_vram_total")
        load = read_number(base + "/gpu_busy_percent")
        gpu = None
        if used is not None and total:
            gpu = {"pct": rnd(clamp(100 * used / total, 0, 100), 1),
                   "usedMiB": round(used / MIB), "totalMiB": round(total / MIB), "celsius": None}
        self.values["gpu"] = gpu
        self.values["gfx"] = None if load is None else {"pct": rnd(clamp(load, 0, 100), 1)}

    # ------------------------------------------------------------ filesystems

    def _fs_usage(self, path):
        if not path or not os.path.exists(path):
            return None
        try:
            st = os.statvfs(path)
        except OSError:
            return None
        block = st.f_frsize or st.f_bsize or 512
        total = st.f_blocks * block
        if total <= 0:
            return None
        used = max(0, (st.f_blocks - st.f_bfree) * block)
        avail = st.f_bavail * block
        # Same convention as df: root-reserved blocks are left out.
        denom = used + avail
        pct = clamp(100.0 * used / denom, 0, 100) if denom > 0 else 0
        return pct, used, total

    def sample_disk(self):
        usage = self._fs_usage(self.disk_mount)
        self.values["ssd"] = None if not usage else {
            "pct": rnd(usage[0], 1), "mount": self.disk_mount,
            "usedBytes": usage[1], "totalBytes": usage[2],
        }
        self.mounts = self._list_mounts()

    def _list_mounts(self):
        text = read_text("/proc/mounts") or ""
        result, seen = [], set()
        for line in text.splitlines():
            parts = line.split(" ")
            if len(parts) < 3:
                continue
            device, mount, fstype = unescape_mount(parts[0]), unescape_mount(parts[1]), parts[2]
            if mount in seen or not device.startswith("/dev/") or fstype in PSEUDO_FSTYPES:
                continue
            if mount.startswith(REMOVABLE_PREFIXES):
                continue
            # Btrfs subvolumes of one device all report the same usage.
            key = (device, fstype)
            if fstype == "btrfs" and key in seen:
                continue
            seen.add(mount)
            seen.add(key)
            usage = self._fs_usage(mount)
            if usage:
                result.append({"mount": mount, "pct": rnd(usage[0], 1)})
        return result

    # ----------------------------------------------------------------- output

    def sample_fast(self):
        now = time.monotonic()
        self._sample_cpu(now)
        self._sample_mem()
        self._sample_net(now)
        self._sample_temp(now)

    def snapshot(self):
        out = dict(self.values)
        out["mounts"] = self.mounts
        return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--interval", type=int, default=1000)
    parser.add_argument("--gpu-interval", type=int, default=5000)
    parser.add_argument("--mount", default="/")
    parser.add_argument("--no-gpu", action="store_true")
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()

    fast = clamp(args.interval, 250, 10000) / 1000.0
    gpu_every = clamp(args.gpu_interval, 1000, 60000) / 1000.0
    parent = os.getppid()

    sampler = Sampler(args.mount, not args.no_gpu)
    sampler.sample_gpu()
    next_fast = time.monotonic()
    next_gpu = next_fast + gpu_every
    next_disk = next_fast + DISK_INTERVAL

    while True:
        now = time.monotonic()
        if now >= next_gpu:
            sampler.sample_gpu()
            next_gpu = now + gpu_every
        if now >= next_disk:
            sampler.sample_disk()
            next_disk = now + DISK_INTERVAL
        sampler.poll_gpu()
        sampler.sample_fast()
        try:
            sys.stdout.write(json.dumps(sampler.snapshot(), separators=(",", ":")) + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, OSError):
            return
        if args.once:
            return
        # The shell went away without stopping us.
        if os.getppid() != parent:
            return
        next_fast += fast
        delay = next_fast - time.monotonic()
        if delay < 0:
            next_fast = time.monotonic()
            delay = fast
        time.sleep(delay)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
