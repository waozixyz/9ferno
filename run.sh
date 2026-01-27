#!/bin/sh
# TaijiOS build and run script
# Works on NixOS and OpenBSD

set -e

# Optional clean build flag
CLEAN_BUILD=""
if [ "$1" = "--clean" ]; then
    CLEAN_BUILD="clean"
    shift
fi

# Determine OS
if [ -f /etc/NIXOS ]; then
    OS="nixos"
elif [ "$(uname)" = "OpenBSD" ]; then
    OS="openbsd"
else
    OS="linux"
fi

echo "=== TaijiOS Build & Run Script ==="
echo "Detected OS: $OS"
echo ""

# Change to script directory
cd "$(dirname "$0")"

# Function to build on NixOS
build_nixos() {
    echo "Building on NixOS using nix-shell..."
    nix-shell --run "export PATH=\"\$PWD/Linux/amd64/bin:\$PATH\"; export ROOT=\"\$PWD\"; mk $CLEAN_BUILD install"
}

# Function to build on OpenBSD
build_openbsd() {
    echo "Building on OpenBSD..."
    # OpenBSD native build
    export SYSTARG=OpenBSD
    export OBJTYPE=amd64
    export ROOT="$(pwd)"

    # Build mk first if needed
    if [ ! -f Linux/amd64/bin/mk ]; then
        echo "Building mk build tool..."
        (cd mk && mk && mv mk /usr/local/bin/ || true)
    fi

    # Build and install
    mk $CLEAN_BUILD install
}

# Function to build on generic Linux
build_linux() {
    echo "Building on generic Linux..."
    export PATH="$PWD/Linux/amd64/bin:$PATH"
    export ROOT="$(pwd)"
    mk $CLEAN_BUILD install
}

# Build based on OS
case "$OS" in
    nixos)
        build_nixos
        ;;
    openbsd)
        build_openbsd
        ;;
    linux)
        build_linux
        ;;
esac

echo ""
echo "=== Build Complete! ==="
echo ""

# Set up namespace for emu
EMU_ROOT="$(pwd)"
export ROOT="$EMU_ROOT"

# Function to set up TaijiOS namespace directory structure
setup_namespace() {
    ROOT="$1"

    echo "Setting up TaijiOS namespace..."

    # Create standard system directories
    mkdir -p "$ROOT/tmp"
    mkdir -p "$ROOT/mnt"

    # Create /n network namespace structure
    mkdir -p "$ROOT/n"
    mkdir -p "$ROOT/n/cd"
    mkdir -p "$ROOT/n/client"
    mkdir -p "$ROOT/n/client/chan"
    mkdir -p "$ROOT/n/client/dev"
    mkdir -p "$ROOT/n/disk"
    mkdir -p "$ROOT/n/dist"
    mkdir -p "$ROOT/n/dump"
    mkdir -p "$ROOT/n/ftp"
    mkdir -p "$ROOT/n/gridfs"
    mkdir -p "$ROOT/n/kfs"
    mkdir -p "$ROOT/n/local"
    mkdir -p "$ROOT/n/rdbg"
    mkdir -p "$ROOT/n/registry"
    mkdir -p "$ROOT/n/remote"

    # Create services directories
    mkdir -p "$ROOT/services/logs"

    # Set permissions (match mkfile behavior)
    chmod 555 "$ROOT/n"
    chmod 755 "$ROOT/tmp"
    chmod 755 "$ROOT/mnt"

    echo "Namespace setup complete."
}

# Function to run on NixOS
run_nixos() {
    echo "Starting emu on NixOS..."
    echo "Type 'exit' to quit emu"
    echo ""

    # Set up namespace before starting emu
    setup_namespace "$ROOT"

    # Run emu with nix-shell environment
    exec nix-shell --run "
        export PATH='$ROOT/Linux/amd64/bin:\$PATH'
        export ROOT='$ROOT'
        cd '$ROOT'
        exec Linux/amd64/bin/emu -r '$ROOT' "\$@"
    " -- "$@"
}

# Function to run on OpenBSD
run_openbsd() {
    echo "Starting emu on OpenBSD..."
    echo "Type 'exit' to quit emu"
    echo ""

    # Set up namespace before starting emu
    setup_namespace "$ROOT"

    export PATH="$ROOT/Linux/amd64/bin:$PATH"

    # Run emu
    exec "$ROOT/Linux/amd64/bin/emu" -r "$ROOT" "$@"
}

# Function to run on generic Linux
run_linux() {
    echo "Starting emu..."
    echo "Type 'exit' to quit emu"
    echo ""

    # Set up namespace before starting emu
    setup_namespace "$ROOT"

    export PATH="$ROOT/Linux/amd64/bin:$PATH"

    # Run emu
    exec "$ROOT/Linux/amd64/bin/emu" -r "$ROOT" "$@"
}

# Run based on OS
case "$OS" in
    nixos)
        run_nixos "$@"
        ;;
    openbsd)
        run_openbsd "$@"
        ;;
    linux)
        run_linux "$@"
        ;;
esac
