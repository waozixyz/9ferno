#!/bin/sh
# Build Plan 9 assemblers in Inferno

set -e

INFROOT=$(pwd)
export INFROOT

echo "=== Building Plan 9 Assemblers in Inferno ==="
echo ""

# Set build environment
export SYSHOST=Linux
export SYSTARG=Linux
export OBJTYPE=amd64
export SHELLTYPE=sh

# Add mk to PATH
export PATH="$INFROOT/utils/mk:$PATH"

echo "Building assemblers..."
echo ""

# Build 6a (AMD64 assembler)
if [ -d "$INFROOT/utils/6a" ]; then
    echo "Building 6a (AMD64 assembler)..."
    cd "$INFROOT/utils/6a"
    mk install
    echo "✓ 6a built"
else
    echo "ℹ 6a source not found - skipping"
fi

echo ""
echo "Building 6c (AMD64 compiler)..."
if [ -d "$INFROOT/utils/6c" ]; then
    cd "$INFROOT/utils/6c"
    mk install
    echo "✓ 6c built"
else
    echo "ℹ 6c source not found - skipping"
fi

echo ""
echo "Building 6l (AMD64 linker)..."
if [ -d "$INFROOT/utils/6l" ]; then
    cd "$INFROOT/utils/6l"
    mk install
    echo "✓ 6l built"
else
    echo "ℹ 6l source not found - skipping"
fi

echo ""
echo "=== Summary ==="
echo "Available Plan 9 assemblers:"
ls -1 $INFROOT/Linux/amd64/bin/*a 2>/dev/null | xargs -n1 basename
echo ""
echo "Available Plan 9 compilers:"
ls -1 $INFROOT/Linux/amd64/bin/*c 2>/dev/null | xargs -n1 basename | grep -v "data2c" | grep -v "5coff" | grep -v "5cv"
echo ""
echo "Available Plan 9 linkers:"
ls -1 $INFROOT/Linux/amd64/bin/*l 2>/dev/null | xargs -n1 basename | grep -v "data2s"
