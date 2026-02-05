#!/bin/sh
# TaijiOS build and run script

cd "$(dirname "$0")"
export ROOT="$(pwd)"
export PATH="$ROOT/Linux/amd64/bin:$PATH"

# Default to shell if no program specified
if [ $# -eq 0 ]; then
    set -- dis/sh.dis
fi

mk && mk all

# Set up namespace
mkdir -p "$ROOT/tmp" "$ROOT/mnt" "$ROOT/n"
chmod 555 "$ROOT/n"
chmod 755 "$ROOT/tmp" "$ROOT/mnt"

# Run emu
exec "$ROOT/Linux/amd64/bin/emu" -p heap=128m -r "$ROOT" "$@"
