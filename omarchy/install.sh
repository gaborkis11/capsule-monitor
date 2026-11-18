#!/usr/bin/env bash
#
# Capsule System Monitor - installer for the Omarchy bar.
#
# An Omarchy shell plugin is just a directory under ~/.config/omarchy/plugins.
# This script copies it there and, on a first install, puts the widget on the
# bar next to the clock.

set -euo pipefail

ID="gaborkis.capsule-monitor"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/capsule-monitor"
DEST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
DEST="$DEST_DIR/capsule-monitor"

if [ ! -f "$SRC/manifest.json" ]; then
    echo "Error: $SRC not found. Run this script from the repository." >&2
    exit 1
fi

if ! command -v omarchy >/dev/null 2>&1; then
    echo "Error: the omarchy command was not found. This installer is for Omarchy." >&2
    echo "On Linux Mint / Cinnamon, use ../install.sh instead." >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required (the data sampler is a small Python script)." >&2
    exit 1
fi

mkdir -p "$DEST_DIR"

update=false
if [ -d "$DEST" ]; then
    update=true
    echo "Updating existing installation in $DEST"
    rm -rf "$DEST"
else
    echo "Installing to $DEST"
fi

cp -r "$SRC" "$DEST"
rm -rf "$DEST/__pycache__"

if $update; then
    # A running shell keeps the QML it compiled; a restart picks up the update.
    omarchy restart shell >/dev/null 2>&1 || true
    echo
    echo "Done. The shell was restarted to load the new version."
else
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    omarchy plugin enable "$ID" centerBegin --index 0
    echo
    echo "Done. The capsule sits to the left of the clock."
    echo "Drag it anywhere on the bar to move it."
fi

echo
echo "Settings live in ~/.config/omarchy/shell.json, in the \"$ID\" entry."
echo "See the README for the available keys."
