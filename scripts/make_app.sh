#!/bin/bash
# Builds Murmur.app from the SwiftPM release binary.
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

# MURMUR_APP_PATH lets make_release.sh assemble into dist/ without touching the build this Mac is running.
APP="${MURMUR_APP_PATH:-build/Murmur.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Murmur "$APP/Contents/MacOS/Murmur"

# MLX's GPU kernels for "Translate into" (Gemma 4 / EuroLLM): `swift build` can't compile Metal shaders, so
# build_mlx_metallib.sh makes them once per mlx-swift version. In the app they go in Contents/Resources (codesign
# rejects a plain file in Contents/MacOS) and `Translator` points MLX at them; the plain build finds its copy next to
# the binary.
scripts/build_mlx_metallib.sh
cp Vendor/mlx.metallib "$APP/Contents/Resources/mlx.metallib"
cp Vendor/mlx.metallib .build/release/mlx.metallib

# sherpa-onnx is the one vendored engine that's a real dynamic framework
# (whisper.xcframework/harper.xcframework are static, fully linked into the
# Murmur binary above — nothing further needed for those). SwiftPM resolves
# it at build time by copying sherpa_onnx.framework next to the built
# Murmur binary in .build/release/ itself, which is exactly where its own
# @loader_path rpath expects to find it — so it has to travel with the
# binary here too, in Contents/MacOS/, not just get left behind in .build/.
if [ -d ".build/release/sherpa_onnx.framework" ]; then
    cp -R ".build/release/sherpa_onnx.framework" "$APP/Contents/MacOS/sherpa_onnx.framework"
fi

# Sparkle (official release builds update through it — see SparkleUpdater.swift) links the same way as sherpa-onnx:
# the binary finds it through its @loader_path rpath, so it goes next to the binary. Its XPC services only exist for
# sandboxed apps, and Murmur isn't one, so they're left out rather than shipped as unused signed code.
if [ -d ".build/release/Sparkle.framework" ]; then
    ditto ".build/release/Sparkle.framework" "$APP/Contents/MacOS/Sparkle.framework"
    rm -rf "$APP/Contents/MacOS/Sparkle.framework/Versions/B/XPCServices"
fi

# Bundled fonts: copied straight into Contents/Resources rather than
# SwiftPM's generated Murmur_Murmur.bundle, which it expects at the .app's
# top level — codesign won't seal resources living outside Contents/, and
# fails to verify. FontLoader checks Bundle.main (this location) first.
if [ -d ".build/release/Murmur_Murmur.bundle/Fonts" ]; then
    mkdir -p "$APP/Contents/Resources/Fonts"
    cp .build/release/Murmur_Murmur.bundle/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"
fi

# App icon (source: Resources/Murmur.svg — rerun scripts/make_icon.sh to
# regenerate Resources/Murmur.icns after changing the SVG).
if [ -f "Resources/Murmur.icns" ]; then
    cp Resources/Murmur.icns "$APP/Contents/Resources/Murmur.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>local.murmur</string>
    <key>CFBundleName</key>
    <string>Murmur</string>
    <key>CFBundleExecutable</key>
    <string>Murmur</string>
    <key>CFBundleIconFile</key>
    <string>Murmur</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.1.0</string>
    <key>CFBundleVersion</key>
    <string>4</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Murmur records your voice while you hold the dictation key so it can transcribe it on-device.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Notetaker checks for an in-progress calendar event only to give a captured meeting note a real title — it never reads or changes your calendar otherwise.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>If you turn on browser meeting detection, Notetaker reads your active browser tab's URL only to check whether it looks like a meeting link — never your browsing history, and never sent anywhere.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>local.murmur.activate</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>murmurmac</string>
            </array>
        </dict>
    </array>
    <key>NSHumanReadableCopyright</key>
    <string>Local build — no data leaves this Mac.</string>
</dict>
</plist>
PLIST

# The stable local identity is what keeps macOS permission grants valid
# across rebuilds: TCC stores a code requirement at the moment you grant
# Microphone/Accessibility, then re-validates every launch. A self-signed
# certificate pins that requirement to the certificate, which survives
# rebuilds. An ad-hoc signature (-) pins it to the binary's cdhash, which
# changes on EVERY build — so macOS stops recognising the app and asks for
# permission again each time.
#
# Ad-hoc is therefore a hard failure, not a silent fallback: one ad-hoc
# build is enough to invalidate a grant recorded against the certificate.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "WhisperFlow Dev"; then
    # Nested dynamic code needs its own signature before the outer app
    # bundle is sealed. Order matters: libonnxruntime.dylib (a loose
    # runtime dependency, not the framework's own main binary) needs its
    # own leaf signature first, since the framework-bundle signature just
    # below hashes it as a sealed resource — signing the bundle before its
    # contents are in their final signed state produced a "nested code is
    # modified or invalid" failure on the outer app signature. Signing
    # `sherpa_onnx.framework` itself (not the loose `sherpa_onnx` binary
    # inside it) is what actually seals the bundle structure (Info.plist,
    # Versions symlinks) the outer --deep verification expects to find.
    if [ -d "$APP/Contents/MacOS/sherpa_onnx.framework" ]; then
        codesign --force --sign "WhisperFlow Dev" \
            "$APP/Contents/MacOS/sherpa_onnx.framework/Versions/A/libonnxruntime.dylib"
        codesign --force --sign "WhisperFlow Dev" \
            "$APP/Contents/MacOS/sherpa_onnx.framework"
    fi
    # Sparkle inside-out: its installer helper and updater app first, then the framework that seals them.
    if [ -d "$APP/Contents/MacOS/Sparkle.framework" ]; then
        codesign --force --sign "WhisperFlow Dev" "$APP/Contents/MacOS/Sparkle.framework/Versions/B/Autoupdate"
        codesign --force --sign "WhisperFlow Dev" "$APP/Contents/MacOS/Sparkle.framework/Versions/B/Updater.app"
        codesign --force --sign "WhisperFlow Dev" "$APP/Contents/MacOS/Sparkle.framework"
    fi
    codesign --force --sign "WhisperFlow Dev" "$APP"
    echo "Signed with 'WhisperFlow Dev'."
else
    echo "ERROR: signing identity 'WhisperFlow Dev' not found." >&2
    echo "Run scripts/make_signing_cert.sh first — signing ad-hoc would make macOS" >&2
    echo "re-prompt for Microphone and Accessibility on every single rebuild." >&2
    exit 1
fi

echo "Built $APP"
