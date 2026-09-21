#!/bin/bash
# Packages the speaker-labels add-on (FluidAudio's streaming Sortformer diarizer model)
# into a versioned zip + manifest for our own Cloudflare R2 bucket. Run this whenever the
# add-on's model files change; it never touches Hugging Face and never deletes anything
# already uploaded.
#
# Usage: scripts/package-addon.sh [source-dir] [output-dir]
#   source-dir defaults to the FluidAudio Sortformer cache on this Mac:
#     ~/Library/Application Support/FluidAudio/Models/sortformer
#   output-dir defaults to ./addon-build/speaker-labels/v1 inside the repo.
#
# Verified against FluidAudio 0.15.7 source (Diarizer/Sortformer/SortformerModelInference.swift):
# ModelHub caches Sortformer as an already-compiled `.mlmodelc` (config.json + v3/fp16/
# Sortformer_v2.1.mlmodelc), loaded at runtime with `MLModel(contentsOf:)` - no on-device
# compile step. That whole directory is what we ship; `rootPath` in the manifest points at
# the .mlmodelc inside it.

set -euo pipefail

ADDON_ID="speaker-labels"
ADDON_VERSION=1
ADDON_DISPLAY_VERSION="1.0"
MIN_APP_BUILD=1
ROOT_PATH="v3/fp16/Sortformer_v2.1.mlmodelc"

SOURCE_DIR="${1:-$HOME/Library/Application Support/FluidAudio/Models/sortformer}"
OUT_DIR="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/addon-build}"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "error: source directory not found: $SOURCE_DIR" >&2
  exit 1
fi
if [ ! -f "$SOURCE_DIR/config.json" ] || [ ! -d "$SOURCE_DIR/$ROOT_PATH" ]; then
  echo "error: $SOURCE_DIR does not look like a Sortformer cache (missing config.json or $ROOT_PATH)" >&2
  exit 1
fi

VERSION_DIR="$OUT_DIR/$ADDON_ID/v$ADDON_VERSION"
mkdir -p "$VERSION_DIR"
ZIP_NAME="$ADDON_ID-v$ADDON_VERSION.zip"
ZIP_PATH="$VERSION_DIR/$ZIP_NAME"
MANIFEST_PATH="$VERSION_DIR/manifest.json"
CATALOG_PATH="$OUT_DIR/catalog.json"

rm -f "$ZIP_PATH"

echo "Packaging $SOURCE_DIR -> $ZIP_PATH"

# Deterministic-ish zip: ditto with --norsrc --noextattr skips resource forks and xattrs;
# we also strip .DS_Store before zipping so a Finder visit never leaks into the archive.
find "$SOURCE_DIR" -name ".DS_Store" -delete

(cd "$SOURCE_DIR" && ditto -c -k --norsrc --noextattr . "$ZIP_PATH")

ZIP_SIZE=$(stat -f%z "$ZIP_PATH")
SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
INSTALLED_SIZE=$(find "$SOURCE_DIR" -type f -exec stat -f%z {} \; | awk '{s+=$1} END {print s}')

cat > "$MANIFEST_PATH" <<JSON
{
  "id": "$ADDON_ID",
  "version": $ADDON_VERSION,
  "displayVersion": "$ADDON_DISPLAY_VERSION",
  "zipSizeBytes": $ZIP_SIZE,
  "installedSizeBytes": $INSTALLED_SIZE,
  "sha256": "$SHA256",
  "minAppBuild": $MIN_APP_BUILD,
  "rootPath": "$ROOT_PATH"
}
JSON

cat > "$CATALOG_PATH" <<JSON
{
  "addons": {
    "$ADDON_ID": {
      "version": $ADDON_VERSION,
      "manifest": "$ADDON_ID/v$ADDON_VERSION/manifest.json"
    }
  }
}
JSON

echo "zip:      $ZIP_PATH ($ZIP_SIZE bytes)"
echo "manifest: $MANIFEST_PATH"
echo "catalog:  $CATALOG_PATH"
echo "sha256:   $SHA256"
echo
echo "Next: upload with scripts/upload-addon.sh (or the wrangler commands in Engine/README.md)."
