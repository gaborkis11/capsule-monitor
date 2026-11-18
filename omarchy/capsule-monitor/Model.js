.pragma library

// Capsule System Monitor - display rules (port of the Cinnamon applet.js rule
// layer). Pure functions: sampler values + settings in, cell descriptors out.

var MIB = 1024 * 1024
var GIB = 1024 * MIB
var TIB = 1024 * GIB
var KIB = 1024
var NET_BARS = 20
var EM_DASH = "—"

var ELEMENTS = {
  mem: { id: "mem", label: "MEM", kind: "pct",     unit: "%",      tip: "Memória",      absFrom: "bytes" },
  cpu: { id: "cpu", label: "CPU", kind: "pct",     unit: "%",      tip: "Processzor",   sustained: true },
  gpu: { id: "gpu", label: "GPU", kind: "pct",     unit: "%",      tip: "Videómemória", absFrom: "mib" },
  ssd: { id: "ssd", label: "SSD", kind: "pct",     unit: "%",      tip: "Lemez",        absFrom: "bytes" },
  net: { id: "net", label: "",    kind: "net",     unit: "",       tip: "Hálózat" },
  swp: { id: "swp", label: "SWP", kind: "pct",     unit: "%",      tip: "Swap",         absFrom: "bytes" },
  gfx: { id: "gfx", label: "GFX", kind: "pct",     unit: "%",      tip: "GPU terhelés" },
  tmp: { id: "tmp", label: "TMP", kind: "celsius", unit: "°", tip: "Hőmérséklet",  sustained: true }
}

var DEFAULT_ELEMENTS = ["mem", "cpu", "gpu", "ssd", "net"]
var DEFAULT_THRESHOLDS = { mem: 85, cpu: 90, gpu: 90, ssd: 80, swp: 50, gfx: 100, tmp: 85 }

function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v) }

function toNumber(v) { return (typeof v === "number" && isFinite(v)) ? v : null }

function huNumber(v, decimals) { return v.toFixed(decimals).replace(".", ",") }

function padRight(s, n) { s = String(s); while (s.length < n) s += " "; return s }
function padLeft(s, n) { s = String(s); while (s.length < n) s = " " + s; return s }

// Known ids only, each once, in the order given.
function normalizeElements(list) {
  if (!Array.isArray(list)) return DEFAULT_ELEMENTS.slice()
  var out = [], seen = {}
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    var id = (entry && typeof entry === "object") ? entry.id : entry
    if (entry && typeof entry === "object" && entry.show === false) continue
    id = String(id || "").toLowerCase()
    if (!ELEMENTS[id] || seen[id]) continue
    seen[id] = true
    out.push(id)
  }
  return out
}

// Bytes per second -> at most four characters plus a one letter unit.
function netSpeed(bps) {
  var value = toNumber(bps)
  if (value === null || value < 0) return { text: EM_DASH, unit: "" }
  var unit = "k", scaled = value / KIB
  if (value >= GIB) { unit = "G"; scaled = value / GIB }
  else if (value >= MIB) { unit = "M"; scaled = value / MIB }
  var text
  if (scaled < 0.05) text = "0"
  else if (scaled >= 99.95) text = String(Math.round(scaled))
  else text = huNumber(scaled, 1)
  return { text: text, unit: unit }
}

// Used amount in binary gigabytes: "12,8"+"G", "468"+"G", "1,5"+"T".
function absSize(bytes) {
  var value = toNumber(bytes)
  if (value === null || value < 0) return { text: EM_DASH, unit: "" }
  var unit = "G", scaled = value / GIB
  if (scaled >= 999.5) { unit = "T"; scaled = value / TIB }
  var text
  if (scaled < 0.05) text = "0"
  else if (scaled >= 99.95) text = String(Math.round(scaled))
  else text = huNumber(scaled, 1)
  return { text: text, unit: unit }
}

function sizePair(used, total) {
  var u = used / GIB, t = total / GIB
  var d = t >= 100 ? 0 : 1
  return huNumber(u, d) + " / " + huNumber(t, d) + " GB"
}

function usedBytes(el, node) {
  if (!node || !el.absFrom) return null
  if (el.absFrom === "mib") {
    var mib = toNumber(node.usedMiB)
    return mib === null ? null : mib * MIB
  }
  return toNumber(node.usedBytes)
}

function threshold(el, thresholds) {
  var t = toNumber(Number(thresholds && thresholds[el.id] !== undefined ? thresholds[el.id] : DEFAULT_THRESHOLDS[el.id]))
  if (t === null) return null
  // For a percentage a threshold of 100 or more means "never alert".
  if (el.kind === "pct" && t >= 100) return null
  return t
}

function average(ring) {
  if (!ring || !ring.length) return null
  var s = 0
  for (var i = 0; i < ring.length; i++) s += ring[i]
  return s / ring.length
}

// The value an alert is judged on: cpu and tmp use a rolling average so a
// spike never turns the capsule orange.
function sustained(id, instant, providerAvg, cfg, rings) {
  if (!(cfg.sustainSeconds > 0)) return instant
  if (cfg.sustainSeconds === 10 && toNumber(providerAvg) !== null) return providerAvg
  var local = average(rings[id])
  return local === null ? instant : local
}

function netBars(history) {
  var src = Array.isArray(history) ? history.slice(-NET_BARS) : []
  var bars = []
  while (bars.length < NET_BARS - src.length) bars.push(0)
  for (var i = 0; i < src.length; i++) {
    var r = toNumber(src[i])
    bars.push(r === null ? 0 : clamp(r, 0, 1))
  }
  return bars
}

// One cell descriptor: { text, unit, ratio, alert } or, for the network,
// { barsUp, barsDown, upText, upUnit, downText, downUnit }. null = no data.
function displayFor(id, values, cfg, rings) {
  var el = ELEMENTS[id]
  values = values || {}
  if (el.kind === "net") {
    var net = values.net
    if (!net) return null
    var up = netSpeed(net.upBps), down = netSpeed(net.downBps)
    return {
      barsUp: netBars(net.historyUp), barsDown: netBars(net.historyDown),
      upText: up.text, upUnit: up.unit, downText: down.text, downUnit: down.unit
    }
  }
  var th = threshold(el, cfg.thresholds)
  if (el.kind === "celsius") {
    var tnode = values.tmp
    var c = tnode ? toNumber(tnode.celsius) : null
    if (c === null) return null
    var judgedT = sustained("tmp", c, null, cfg, rings)
    return {
      text: String(Math.round(c)), unit: el.unit,
      ratio: clamp(c / 100, 0, 1),
      alert: th !== null && judgedT !== null && judgedT >= th
    }
  }
  var node = values[id]
  var pct = node ? toNumber(node.pct) : null
  if (pct === null) return null
  var judged = el.sustained ? sustained(id, pct, node.avg10, cfg, rings) : pct
  var text = String(Math.round(pct)), unit = el.unit
  if (el.absFrom && cfg.modes && cfg.modes[id] === "abs") {
    var abs = absSize(usedBytes(el, node))
    if (abs.unit) { text = abs.text; unit = abs.unit }
  }
  return {
    text: text, unit: unit, ratio: clamp(pct / 100, 0, 1),
    alert: th !== null && judged !== null && judged >= th
  }
}

// ----------------------------------------------------------------- tooltip

var TIP_LABEL_COLS = 22
var TIP_VALUE_COLS = 3

function sustainSuffix(id, node, unit, cfg, rings) {
  if (!(cfg.sustainSeconds > 0)) return ""
  var instant = node ? toNumber(id === "tmp" ? node.celsius : node.pct) : null
  var avg = sustained(id, instant, node && id === "cpu" ? node.avg10 : null, cfg, rings)
  if (avg === null) return ""
  return "   " + Math.round(cfg.sustainSeconds) + " mp átlag: " + Math.round(avg) + unit
}

function tooltipLine(id, values, cfg, rings) {
  var el = ELEMENTS[id]
  var label = el.tip
  if (id === "ssd") label += " (" + ((values.ssd && values.ssd.mount) || cfg.diskMount) + ")"
  var cell = displayFor(id, values, cfg, rings)
  var head = padRight(label, TIP_LABEL_COLS)
  var body
  if (!cell) body = padLeft(EM_DASH, TIP_VALUE_COLS + 1)
  else if (el.kind === "net") {
    var net = values.net
    body = "↓ " + huNumber(net.downBps / MIB, 1) + "   ↑ " + huNumber(net.upBps / MIB, 1) + " MB/s"
  } else if (el.kind === "celsius") {
    body = padLeft(cell.text, TIP_VALUE_COLS) + " °C" + sustainSuffix("tmp", values.tmp, " °C", cfg, rings)
  } else {
    var node = values[id]
    body = padLeft(Math.round(node.pct), TIP_VALUE_COLS) + "%"
    if (id === "cpu") body += sustainSuffix("cpu", node, "%", cfg, rings)
    else if (id === "gpu") {
      if (toNumber(node.usedMiB) !== null && toNumber(node.totalMiB) !== null)
        body += "   " + sizePair(node.usedMiB * MIB, node.totalMiB * MIB)
    } else if (toNumber(node.usedBytes) !== null && toNumber(node.totalBytes) !== null) {
      body += "   " + sizePair(node.usedBytes, node.totalBytes)
    }
  }
  return (cell && cell.alert ? "! " : "  ") + head + body
}

function tooltip(ids, values, cfg, rings) {
  values = values || {}
  var lines = []
  for (var i = 0; i < ids.length; i++) lines.push(tooltipLine(ids[i], values, cfg, rings))
  if (!ids.length) lines.push("Nincs bekapcsolt elem.")
  var mounts = values.mounts || []
  if (ids.indexOf("ssd") >= 0 && mounts.length) {
    lines.push("")
    lines.push("  Kötetek:")
    for (var m = 0; m < mounts.length; m++) {
      var p = toNumber(mounts[m].pct)
      lines.push("    " + padRight(mounts[m].mount, TIP_LABEL_COLS - 2) +
                 (p === null ? EM_DASH : padLeft(Math.round(p), TIP_VALUE_COLS) + "%"))
    }
  }
  // The shared tooltip centres its text: equal-length lines keep the columns.
  var width = 0
  for (var j = 0; j < lines.length; j++) width = Math.max(width, lines[j].length)
  for (var k = 0; k < lines.length; k++) lines[k] = padRight(lines[k], width)
  return lines.join("\n")
}
