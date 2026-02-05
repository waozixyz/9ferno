#!/bin/sh
# TaijiOS build and run script
# Works on NixOS and OpenBSD

# Don't use set -e to allow graceful handling of "Text file busy" errors
# when emu is already running

# Optional clean build flag
CLEAN_BUILD=""
BUILD_ONLY=""
if [ "$1" = "--clean" ]; then
    CLEAN_BUILD="clean"
    shift
elif [ "$1" = "--build" ]; then
    BUILD_ONLY="yes"
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
echo "Usage: $0 [--clean|--build] [program.dis [args...]]"
echo "  --clean : Clean build before running"
echo "  --build : Build only, don't run"
echo "  If no program specified, runs the Inferno shell (dis/sh.dis)"
echo ""

# Change to script directory
cd "$(dirname "$0")"

# Function to build acme modules explicitly
build_acme_modules() {
    echo "Building acme modules using mk..."
    LIMBO="$ROOT/Linux/amd64/bin/limbo"
    export PATH="$ROOT/Linux/amd64/bin:$PATH"

    (cd "$ROOT/appl/acme" && mk install) || echo "  Warning: acme build failed"

    echo "Acme modules build complete."
}

# Function to build wm modules explicitly
build_wm_modules() {
    echo "Building wm modules using mk..."
    export PATH="$ROOT/Linux/amd64/bin:$PATH"

    (cd "$ROOT/appl/wm" && mk install) || echo "  Warning: wm build failed"

    echo "WM modules build complete."
}

# Function to build on NixOS
build_nixos() {
    echo "Building on NixOS using nix-shell..."
    export ROOT="$(pwd)"
    nix-shell --run "export PATH=\"\$PWD/Linux/amd64/bin:\$PATH\"; export ROOT=\"\$PWD\"; mk $CLEAN_BUILD install"

    # Always rebuild acme modules to ensure they're up to date
    build_acme_modules

    # Build wm modules
    build_wm_modules
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

    # Rebuild acme modules
    build_acme_modules

    # Build wm modules
    build_wm_modules
}

# Function to build on generic Linux
build_linux() {
    echo "Building on generic Linux..."
    export ROOT="$(pwd)"

    # Check if mk exists locally, bootstrap if needed
    if [ ! -f "Linux/amd64/bin/mk" ]; then
        echo "mk not found, bootstrapping..."
        if command -v mk >/dev/null 2>&1; then
            # Use system mk to build local mk
            (cd utils/mk && mk install)
        else
            # No mk available - need to build with gcc
            echo "Error: mk not found in PATH"
            echo "Please run ./makemk.sh or install mk"
            exit 1
        fi
    fi

    export PATH="$PWD/Linux/amd64/bin:$PATH"
    mk $CLEAN_BUILD install

    # Rebuild acme modules
    build_acme_modules

    # Build wm modules
    build_wm_modules
}

# Build based on OS
# Note: If emu is running, the final copy may fail with "Text file busy"
# but this is OK - the build still completes successfully
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

# Exit if --build flag was used
if [ -n "$BUILD_ONLY" ]; then
    exit 0
fi

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
    # Default to shell if no program specified
    if [ $# -eq 0 ]; then
        set -- dis/sh.dis
    fi

    echo "Starting emu on NixOS..."
    echo "Running: $*"
    echo "Type 'exit' to quit"
    echo ""

    # Set up namespace before starting emu
    setup_namespace "$ROOT"

    # Run emu directly (nix-shell only needed for building)
    export PATH="$ROOT/Linux/amd64/bin:$PATH"
    exec "$ROOT/Linux/amd64/bin/emu" -p heap=128m -r "$ROOT" "$@"
}

# Function to run on OpenBSD
run_openbsd() {
    # Default to shell if no program specified
    if [ $# -eq 0 ]; then
        set -- dis/sh.dis
    fi

    echo "Starting emu on OpenBSD..."
    echo "Running: $*"
    echo "Type 'exit' to quit"
    echo ""

    # Set up namespace before starting emu
    setup_namespace "$ROOT"

    export PATH="$ROOT/Linux/amd64/bin:$PATH"

    # Run emu
    exec "$ROOT/Linux/amd64/bin/emu" -p heap=128m -r "$ROOT" "$@"
}

# Function to run on generic Linux
run_linux() {
    # Default to shell if no program specified
    if [ $# -eq 0 ]; then
        set -- dis/sh.dis
    fi

    echo "Starting emu..."
    echo "Running: $*"
    echo "Type 'exit' to quit"
    echo ""

    # Set up namespace before starting emu
    setup_namespace "$ROOT"

    export PATH="$ROOT/Linux/amd64/bin:$PATH"

    # Run emu
    exec "$ROOT/Linux/amd64/bin/emu" -p heap=128m -r "$ROOT" "$@"
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
