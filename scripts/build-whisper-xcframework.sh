#!/usr/bin/env bash
# Builds a static, macOS-only whisper.xcframework (Metal embedded) from a
# pinned whisper.cpp tag. Output is git-ignored; regenerate with this script.
set -euo pipefail

WHISPER_TAG="v1.9.1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT}/build/whisper-src"
DEST="${ROOT}/third_party/whisper.xcframework"

command -v cmake >/dev/null 2>&1 || { echo "cmake required: brew install cmake"; exit 1; }

if [[ -d "${DEST}" ]]; then
    echo "whisper.xcframework already present at ${DEST} (delete to rebuild)"; exit 0
fi

rm -rf "${BUILD_DIR}"
git clone --depth 1 --branch "${WHISPER_TAG}" https://github.com/ggml-org/whisper.cpp "${BUILD_DIR}"

# Static xcframework so the app links (no embed/sign). Metal is embedded by the script.
( cd "${BUILD_DIR}" && BUILD_STATIC_XCFRAMEWORK=ON ./build-xcframework.sh )

mkdir -p "${ROOT}/third_party"
# The script emits build-apple/whisper.xcframework with all Apple slices; we
# keep the whole xcframework (macOS slice is what links for platform=macOS).
rm -rf "${DEST}"
cp -R "${BUILD_DIR}/build-apple/whisper.xcframework" "${DEST}"
echo "Built ${DEST}"
