#!/bin/sh
# Build all .b files in this directory and subdirectories

# Build files in subdirectories first (dependencies)
for dir in auth asm auxi dbm disk fs install ip lego limbo mail mash mpc ndb sh spki usb zip; do
    if [ -d "$dir" ]; then
        find "$dir" -name '*.b' -type f | while read -r b; do
            dis="${b%.b}.dis"
            if [ ! -f "$dis" ] || [ "$b" -nt "$dis" ]; then
                echo "Building $dis..."
                limbo -I"$ROOT/module" -gw "$b"
            fi
        done
    fi
done

# Build files in current directory
for b in *.b; do
    if [ -f "$b" ]; then
        dis="${b%.b}.dis"
        if [ ! -f "$dis" ] || [ "$b" -nt "$dis" ]; then
            echo "Building $dis..."
            limbo -I"$ROOT/module" -gw "$b"
        fi
    fi
done
