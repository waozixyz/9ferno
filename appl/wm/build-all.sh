#!/bin/sh
# Build all .b files in this directory

for b in *.b; do
    if [ -f "$b" ]; then
        dis="${b%.b}.dis"
        if [ ! -f "$dis" ] || [ "$b" -nt "$dis" ]; then
            echo "Building $dis..."
            limbo -I"$ROOT/module" -gw "$b"
        fi
    fi
done
