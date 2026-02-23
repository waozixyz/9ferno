{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    # Core build tools
    gcc
    gnumake
    binutils

    # X11 for graphics support (optional but useful)
    xorg.libX11
    xorg.libXext

    # Utilities
    coreutils
    bash
    perl

    # For building emu (Inferno emulator)
    linuxHeaders

    # Debugging tools
    gdb
    valgrind
  ];

  # Set environment variables for the build
  shellHook = ''
    echo "Welcome to TaijiOS (Inferno OS amd64) build environment"

    # Find the TaijiOS root directory by looking for mkfile
    if [ -f mkfile ] && [ -d emu ] && [ -d lib ]; then
      ROOT="$(pwd)"
    elif [ -f ./TaijiOS/mkfile ] && [ -d ./TaijiOS/emu ]; then
      ROOT="$(pwd)/TaijiOS"
    else
      echo "Warning: Cannot find TaijiOS root directory. Please run from the TaijiOS directory."
      ROOT="$(pwd)"
    fi
    export ROOT
    export TAIJI_PATH="$ROOT"
    echo "TaijiOS root: $ROOT"
    echo "Current directory: $(pwd)"
    echo ""
    echo "Quick start:"
    echo "  ./run.sh        - Build and run TaijiOS (recommended)"
    echo "  ./run.sh --clean - Clean build and run TaijiOS"
    echo ""

    # Set PATH for TaijiOS tools
    # Include utils/mk for the mk build tool, and Linux/amd64/bin for built binaries
    export PATH="$ROOT/utils/mk:$ROOT/Linux/amd64/bin:${pkgs.plan9port}/plan9/bin:$PATH"

    # Add X11 library paths to linker search path
    export LD_LIBRARY_PATH="${pkgs.xorg.libX11}/lib:${pkgs.xorg.libXext}/lib:$LD_LIBRARY_PATH"
    export LIBRARY_PATH="${pkgs.xorg.libX11}/lib:${pkgs.xorg.libXext}/lib:$LIBRARY_PATH"

    # Wrapper to run the script
    run9ferno() {
      ./run.sh "$@"
    }

    # Build wrapper (just the build portion)
    build9ferno() {
      ./run.sh "$@"
    }

    # Alias for emu
    emu() {
      ./run.sh "$@"
    }
  '';

  # Hardening disabled for Inferno (it has its own build system)
  hardeningDisable = [ "all" ];
}
