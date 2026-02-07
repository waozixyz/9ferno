#!/usr/bin/env bash
# TaijiOS AppImage Build Script
# Creates a single-file AppImage that bundles the complete TaijiOS experience
#
# Usage on NixOS:
#   nix-shell build/shell-appimage.nix --run './build/build-appimage.sh'

set -e

# ============================================================================
# Configuration
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export ROOT="${SCRIPT_DIR}/.."  # Go up from build/ to project root

APP_NAME="TaijiOS"
APP_VERSION="1.0"
APPDIR="${ROOT}/build/${APP_NAME}.AppDir"
OUTPUT_DIR="${ROOT}/build"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "========================================"
echo "=== Building ${APP_NAME} AppImage ==="
echo "========================================"
echo ""

# ============================================================================
# Check Dependencies (especially on NixOS)
# ============================================================================
check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# Check if we're on NixOS
ON_NIXOS=false
if [ -f /etc/NIXOS ]; then
    ON_NIXOS=true
fi

# Check for required commands
MISSING_DEPS=()

if ! check_command magick && ! check_command convert; then
    MISSING_DEPS+=("imagemagick")
fi

if ! check_command wget && ! check_command curl; then
    MISSING_DEPS+=("wget")
fi

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    if [ "$ON_NIXOS" = true ]; then
        echo -e "${BLUE}[NIXOS]${NC} Missing dependencies: ${MISSING_DEPS[*]}"
        echo ""
        echo "Run with nix-shell to get dependencies:"
        echo "  nix-shell shell-appimage.nix --run './build-appimage.sh'"
        echo ""
        exit 1
    else
        echo -e "${RED}[ERROR]${NC} Missing dependencies: ${MISSING_DEPS[*]}"
        echo "Please install them and try again."
        exit 1
    fi
fi

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_binary() {
    if [ ! -f "$1" ]; then
        log_error "Required binary not found: $1"
        return 1
    fi
    return 0
}

# ============================================================================
# Step 1: Build TaijiOS
# ============================================================================
log_info "Step 1: Building TaijiOS..."

# Change to ROOT directory to run the build
cd "$ROOT"

export PATH="$ROOT/Linux/amd64/bin:$PATH"
mk && mk all

# Verify emu binary exists
EMU_BIN="$ROOT/Linux/amd64/bin/emu"
if ! check_binary "$EMU_BIN"; then
    log_error "Emulator binary not found after build: $EMU_BIN"
    exit 1
fi

log_info "TaijiOS build complete."
echo ""

# ============================================================================
# Step 2: Create AppDir Structure
# ============================================================================
log_info "Step 2: Creating AppDir structure..."

# Clean up any existing AppDir (fix permissions if needed)
if [ -d "$APPDIR" ]; then
    chmod -R u+w "$APPDIR" 2>/dev/null || true
    rm -rf "$APPDIR"
fi

# Create main AppDir directories
mkdir -p "$APPDIR"
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/lib"
mkdir -p "$APPDIR/usr/share/applications"
mkdir -p "$APPDIR/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$APPDIR/usr/share/icons/hicolor/scalable/apps"
mkdir -p "$APPDIR/ROOT"

log_info "AppDir structure created."
echo ""

# ============================================================================
# Step 3: Copy Emulator Binary
# ============================================================================
log_info "Step 3: Copying emulator binary..."

cp "$EMU_BIN" "$APPDIR/emu"
chmod +x "$APPDIR/emu"

EMU_SIZE=$(du -h "$APPDIR/emu" | cut -f1)
log_info "Emulator copied (${EMU_SIZE})."
echo ""

# ============================================================================
# Step 4: Copy TaijiOS Root Filesystem
# ============================================================================
log_info "Step 4: Copying TaijiOS filesystem..."

# Copy compiled bytecode (dis)
if [ -d "dis" ]; then
    cp -r dis "$APPDIR/ROOT/"
    DIS_SIZE=$(du -sh "$APPDIR/ROOT/dis" | cut -f1)
    log_info "  - dis/ copied (${DIS_SIZE})"
else
    log_error "dis directory not found!"
    exit 1
fi

# Copy module definitions
if [ -d "module" ]; then
    cp -r module "$APPDIR/ROOT/"
    MODULE_SIZE=$(du -sh "$APPDIR/ROOT/module" | cut -f1)
    log_info "  - module/ copied (${MODULE_SIZE})"
else
    log_warn "module directory not found, skipping..."
fi

# Copy usr directory
if [ -d "usr" ]; then
    cp -r usr "$APPDIR/ROOT/"
    log_info "  - usr/ copied"
else
    log_warn "usr directory not found, skipping..."
fi

# Copy lib directory (contains wmsetup and other config files)
if [ -d "lib" ]; then
    cp -r lib "$APPDIR/ROOT/"
    LIB_SIZE=$(du -sh "$APPDIR/ROOT/lib" | cut -f1)
    log_info "  - lib/ copied (${LIB_SIZE})"
else
    log_warn "lib directory not found, WM may not work properly..."
fi

# Copy fonts
if [ -d "fonts" ]; then
    cp -r fonts "$APPDIR/ROOT/"
    FONTS_SIZE=$(du -sh "$APPDIR/ROOT/fonts" | cut -f1)
    log_info "  - fonts/ copied (${FONTS_SIZE})"
else
    log_error "fonts directory not found!"
    exit 1
fi

# Copy icons/bitmaps (needed for toolbar and WM UI)
if [ -d "icons" ]; then
    cp -r icons "$APPDIR/ROOT/"
    ICONS_SIZE=$(du -sh "$APPDIR/ROOT/icons" | cut -f1)
    log_info "  - icons/ copied (${ICONS_SIZE})"
else
    log_warn "icons directory not found, WM may be missing bitmaps..."
fi

echo ""

# ============================================================================
# Step 5: Create Runtime Directories
# ============================================================================
log_info "Step 5: Creating runtime directories..."

# Standard directories
mkdir -p "$APPDIR/ROOT/tmp"
mkdir -p "$APPDIR/ROOT/mnt"

# Network namespace structure
mkdir -p "$APPDIR/ROOT/n"
mkdir -p "$APPDIR/ROOT/n"/{cd,client,chan,dev,disk,dist,dump,ftp,gridfs,kfs,local,rdbg,registry,remote}
mkdir -p "$APPDIR/ROOT/n/client"/{chan,dev}
mkdir -p "$APPDIR/ROOT/services/logs"

# Set permissions (match mkfile behavior)
chmod 555 "$APPDIR/ROOT/n"
chmod 755 "$APPDIR/ROOT/tmp"
chmod 755 "$APPDIR/ROOT/mnt"

log_info "Runtime directories created."
echo ""

# ============================================================================
# Step 6: Create AppRun Launcher Script
# ============================================================================
log_info "Step 6: Creating AppRun launcher script..."

cat > "$APPDIR/AppRun" <<'APPRUN_EOF'
#!/bin/bash
# TaijiOS AppImage Launcher
# This script sets up the environment and launches emu with the WM

set -e

# Get AppImage mount point
SELF=$(readlink -f "$0")
HERE=${SELF%/*}

# Set up environment
export ROOT="${HERE}/ROOT"
export LD_LIBRARY_PATH="${HERE}/usr/lib:${LD_LIBRARY_PATH}"

# Ensure runtime directories exist
mkdir -p "$ROOT/tmp" "$ROOT/mnt"

# Check for display
if [ -z "$DISPLAY" ]; then
    echo "Error: DISPLAY environment variable not set"
    echo "Are you running in a graphical environment?"
    exit 1
fi

# Check if wminit.dis exists
if [ ! -f "$ROOT/dis/wminit.dis" ]; then
    echo "Error: wminit.dis not found in $ROOT/dis/"
    exit 1
fi

# Check if wm.dis exists
if [ ! -f "$ROOT/dis/wm/wm.dis" ]; then
    echo "Error: wm.dis not found in $ROOT/dis/wm/"
    exit 1
fi

# Launch Window Manager
cd "$HERE"
exec ./emu -r "$ROOT" /dis/wm/wm.dis "$@"
APPRUN_EOF

chmod +x "$APPDIR/AppRun"
log_info "AppRun launcher created."
echo ""

# ============================================================================
# Step 7: Handle Library Bundling
# ============================================================================
log_info "Step 7: Handling library bundling..."

# Detect if we're on NixOS
ON_NIXOS=false
if [ -f /etc/NIXOS ]; then
    ON_NIXOS=true
fi

if [ "$ON_NIXOS" = true ]; then
    log_warn "Building on NixOS - skipping library bundling."
    log_warn "The AppImage will rely on system libraries or use patchelf."
    log_warn "For best portability, consider building on Ubuntu/Debian."

    # Note: NixOS libraries have different loader paths and won't work
    # in an AppImage for other distros. Users on other distros will need
    # to have libX11, libXext installed (standard on most systems).
else
    # On non-NixOS systems, bundle the X11 libraries
    log_info "Bundling X11 libraries for portability..."

    for lib in libX11.so.6 libXext.so.6 libxcb.so.1 libXau.so.6 libXdmcp.so.6; do
        path=$(find /usr/lib /usr/lib64 /lib /lib64 -name "$lib" 2>/dev/null | head -1)
        if [ -n "$path" ]; then
            cp "$path" "$APPDIR/usr/lib/"
            log_info "  - Bundled: $lib"
        fi
    done
fi

echo ""

# ============================================================================
# Step 8: Create Desktop Entry
# ============================================================================
log_info "Step 8: Creating desktop entry..."

cat > "$APPDIR/taijios.desktop" <<'DESKTOP_EOF'
[Desktop Entry]
Name=TaijiOS
GenericName=Inferno OS Environment
Comment=Run the TaijiOS Window Manager (Inferno OS)
Exec=apprun %F
Icon=taijios
Terminal=false
Type=Application
Categories=System;Emulator;
StartupNotify=true
StartupWMClass=TaijiOS
Keywords=Inferno;Plan9;Operating System;Window Manager;
X-AppImage-Name=TaijiOS
X-AppImage-Version=1.0
DESKTOP_EOF

# Also place it in the standard location
mkdir -p "$APPDIR/usr/share/applications"
cp "$APPDIR/taijios.desktop" "$APPDIR/usr/share/applications/"

log_info "Desktop entry created."
echo ""

# ============================================================================
# Step 9: Create Icon
# ============================================================================
log_info "Step 9: Creating application icon..."

ICON_CREATED=false

# Function to create icon with ImageMagick
create_icon_imagemagick() {
    magick -size 256x256 xc:transparent \
        -fill white -draw "circle 128,128 128,10" \
        -fill black -draw "path 'M 128,10 A 118,118 0 0,1 128,246 A 59,59 0 0,1 128,128 Z'" \
        -fill white -draw "circle 128,75 128,62" \
        -fill black -draw "circle 128,181 128,168" \
        -stroke "#333" -strokewidth 2 -draw "circle 128,128 128,10" \
        "$1" 2>/dev/null
}

# Check if ImageMagick is available
if command -v magick >/dev/null 2>&1; then
    create_icon_imagemagick "$APPDIR/usr/share/icons/hicolor/256x256/apps/taijios.png"
    ICON_CREATED=true
    log_info "Icon created with ImageMagick (magick)."
elif command -v convert >/dev/null 2>&1; then
    # Old ImageMagick version
    convert -size 256x256 xc:transparent \
        -fill white -draw "circle 128,128 128,10" \
        -fill black -draw "path 'M 128,10 A 118,118 0 0,1 128,246 A 59,59 0 0,1 128,128 Z'" \
        -fill white -draw "circle 128,75 128,62" \
        -fill black -draw "circle 128,181 128,168" \
        -stroke "#333" -strokewidth 2 -draw "circle 128,128 128,10" \
        "$APPDIR/usr/share/icons/hicolor/256x256/apps/taijios.png" 2>/dev/null
    ICON_CREATED=true
    log_info "Icon created with ImageMagick (convert)."
fi

# Create SVG icon
cat > "$APPDIR/usr/share/icons/hicolor/scalable/apps/taijios.svg" <<'SVG_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg width="256" height="256" viewBox="0 0 256 256" xmlns="http://www.w3.org/2000/svg">
  <!-- Main circle (white background) -->
  <circle cx="128" cy="128" r="118" fill="white" stroke="#333" stroke-width="2"/>
  <!-- Black half (left side, top to bottom through center) -->
  <path d="M 128,10 A 118,118 0 0,1 128,246 A 59,59 0 0,1 128,128 Z" fill="black"/>
  <!-- Small white circle in black half -->
  <circle cx="128" cy="75" r="13" fill="white"/>
  <!-- Small black circle in white half -->
  <circle cx="128" cy="181" r="13" fill="black"/>
</svg>
SVG_EOF

# Create symbolic links
ln -sf "usr/share/icons/hicolor/256x256/apps/taijios.png" "$APPDIR/.DirIcon"
ln -sf "usr/share/icons/hicolor/256x256/apps/taijios.png" "$APPDIR/taijios.png"

if [ "$ICON_CREATED" = false ]; then
    log_warn "Could not create PNG icon. Please create manually."
    touch "$APPDIR/usr/share/icons/hicolor/256x256/apps/taijios.png"
fi

echo ""

# ============================================================================
# Step 10: Download appimagetool
# ============================================================================
log_info "Step 10: Checking for appimagetool..."

APPIMAGETOOL="$OUTPUT_DIR/appimagetool-x86_64.AppImage"

if [ ! -f "$APPIMAGETOOL" ]; then
    log_info "Downloading appimagetool..."

    # Use wget if available, otherwise try curl
    if command -v wget >/dev/null 2>&1; then
        wget -q --show-progress \
            "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage" \
            -O "$APPIMAGETOOL"
    elif command -v curl >/dev/null 2>&1; then
        curl -L -o "$APPIMAGETOOL" \
            "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
    else
        log_error "Neither wget nor curl found. Cannot download appimagetool."
        exit 1
    fi

    chmod +x "$APPIMAGETOOL"
    log_info "appimagetool downloaded."
else
    log_info "appimagetool already present."
fi

echo ""

# ============================================================================
# Step 11: Build AppImage
# ============================================================================
log_info "Step 11: Building AppImage..."

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# On systems with FUSE issues (like NixOS), extract appimagetool first
# and run the contained binary directly
EXTRACTED_TOOL="$OUTPUT_DIR/appimagetool-squashfs-root/AppRun"

if [ ! -f "$EXTRACTED_TOOL" ]; then
    # Extract appimagetool
    "$APPIMAGETOOL" --appimage-extract-and-run 2>/dev/null || \
    "$APPIMAGETOOL" --appimage-extract >/dev/null 2>&1 || true

    # Move to output directory
    if [ -d "squashfs-root" ]; then
        mv squashfs-root "$OUTPUT_DIR/appimagetool-squashfs-root"
    fi
fi

# Unset SOURCE_DATE_EPOCH to avoid conflict with mksquashfs (NixOS issue)
unset SOURCE_DATE_EPOCH

# Build the AppImage - use extracted binary if available, otherwise try direct
if [ -f "$EXTRACTED_TOOL" ]; then
    ARCH=x86_64 "$EXTRACTED_TOOL" "$APPDIR" "$OUTPUT_DIR/${APP_NAME}-${APP_VERSION}-x86_64.AppImage"
else
    ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$OUTPUT_DIR/${APP_NAME}-${APP_VERSION}-x86_64.AppImage"
fi

echo ""
echo "========================================"
log_info "AppImage created successfully!"
echo "========================================"
echo ""
echo "Location: $OUTPUT_DIR/${APP_NAME}-${APP_VERSION}-x86_64.AppImage"

# Show final size
FINAL_SIZE=$(du -h "$OUTPUT_DIR/${APP_NAME}-${APP_VERSION}-x86_64.AppImage" | cut -f1)
echo "Size: $FINAL_SIZE"
echo ""
echo "To run:"
echo "  chmod +x $OUTPUT_DIR/${APP_NAME}-${APP_VERSION}-x86_64.AppImage"
echo "  ./$OUTPUT_DIR/${APP_NAME}-${APP_VERSION}-x86_64.AppImage"
echo ""
