{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    # Android build tools
    android-studio
    android-tools
    jdk17
    gradle

    # Native build tools
    cmake
    ninja
    pkg-config
    python3

    # Git (for versioning)
    git
  ];

  # Android SDK environment variables
  ANDROID_HOME = "${pkgs.android-studio}/android-sdk";
  ANDROID_SDK_ROOT = "${pkgs.android-studio}/android-sdk";
  GRADLE_OPTS = "-Dorg.gradle.project.java.home=${pkgs.jdk17.home}";

  # Shell hooks to display info
  shellHook = ''
    echo "=================================="
    echo " TaijiOS Android Build Environment"
    echo "=================================="
    echo "ANDROID_HOME: $ANDROID_HOME"
    echo "JAVA_HOME: ${pkgs.jdk17.home}"
    echo ""
    echo "Available commands:"
    echo "  ./build-android.sh build   - Build APK"
    echo "  ./build-android.sh install  - Install to device"
    echo "  ./release.sh all            - Create release APK"
    echo ""
    echo "Connected devices:"
    adb devices || echo "  No devices connected"
    echo "=================================="
  '';
}
