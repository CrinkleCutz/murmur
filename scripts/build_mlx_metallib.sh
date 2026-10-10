#!/bin/bash
# Builds Vendor/mlx.metallib — MLX's GPU kernels, used by "Translate into" (Gemma 4 / EuroLLM).
#
# `swift build` can't compile Metal shaders (mlx-swift's own README says so), so this runs xcodebuild once per
# mlx-swift version on a copy of SwiftPM's own checkout — the exact sources the Murmur binary is built from.
# make_app.sh puts the result next to the Murmur binary, the first place MLX looks for it.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(python3 -c "import json; print([p['state']['version'] for p in json.load(open('Package.resolved'))['pins'] if p['identity'] == 'mlx-swift'][0])")
OUT="Vendor/mlx.metallib"
STAMP="Vendor/mlx.metallib.version"

if [ -f "$OUT" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$VERSION" ]; then
    echo "mlx.metallib for mlx-swift $VERSION is up to date"
    exit 0
fi

[ -d .build/checkouts/mlx-swift ] || swift package resolve

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -R .build/checkouts/mlx-swift "$WORK/mlx-swift"
(cd "$WORK/mlx-swift" && xcodebuild build -scheme MLX -destination 'platform=macOS' -configuration Release \
    -derivedDataPath "$WORK/dd" -quiet)

LIB=$(find "$WORK/dd" -name default.metallib -path "*mlx-swift_Cmlx*" | head -1)
[ -n "$LIB" ] || { echo "xcodebuild produced no default.metallib" >&2; exit 1; }
cp "$LIB" "$OUT"
echo "$VERSION" > "$STAMP"
echo "wrote $OUT (mlx-swift $VERSION, $(du -h "$OUT" | cut -f1))"
