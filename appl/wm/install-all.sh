#!/bin/sh
# Install all .dis files to $DISBIN

for dis in *.dis; do
    if [ -f "$dis" ]; then
        cp "$dis" "$DISBIN/"
    fi
done
