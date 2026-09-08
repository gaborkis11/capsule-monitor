#!/usr/bin/env bash
#
# Capsule System Monitor - installer for a single user.
#
# There is no package to install: a Cinnamon applet is just a directory.
# This script copies it to the place Cinnamon looks in, and that is all.

set -euo pipefail

UUID="capsule-monitor@gaborkis11"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/files/$UUID"
DEST_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/cinnamon/applets"
DEST="$DEST_DIR/$UUID"

if [ ! -d "$SRC" ]; then
    echo "Error: $SRC not found. Run this script from the repository root." >&2
    exit 1
fi

if ! command -v cinnamon >/dev/null 2>&1; then
    echo "Warning: Cinnamon does not seem to be installed on this system." >&2
fi

if ! pkg-config --exists libgtop-2.0 2>/dev/null && [ ! -f /usr/lib/x86_64-linux-gnu/girepository-1.0/GTop-2.0.typelib ]; then
    echo
    echo "This applet needs libgtop with GObject introspection:"
    echo "    sudo apt install gir1.2-gtop-2.0        # Linux Mint, Ubuntu, Debian"
    echo "    sudo dnf install libgtop2               # Fedora"
    echo
fi

mkdir -p "$DEST_DIR"

if [ -d "$DEST" ]; then
    echo "Updating existing installation in $DEST"
    rm -rf "$DEST"
else
    echo "Installing to $DEST"
fi

cp -r "$SRC" "$DEST"

echo
echo "Done."
echo
echo "To add it to your panel:"
echo "  right-click the panel  ->  Applets  ->  find \"Capsule System Monitor\"  ->  +"
echo
echo "It starts automatically with every session once it is on the panel."
echo "Nothing else to set up."
