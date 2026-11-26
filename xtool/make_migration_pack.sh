#!/usr/bin/env bash
# Build a portable source bundle for the xtool / real-device build.
#
#   ./xtool/make_migration_pack.sh                       # source only, default
#   ./xtool/make_migration_pack.sh --with-models         # include ~1.2 GB models
#   ./xtool/make_migration_pack.sh /path/to/output.tgz   # custom output path
#
# Source-only bundles keep the Models/ directories (with .gitkeep placeholders)
# but omit the large binaries; run xtool/prepare_models.py on the target machine.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARENT="$(dirname "$REPO")"
NAME="$(basename "$REPO")"

WITH_MODELS=0
OUT=""
for arg in "$@"; do
  case "$arg" in
    --with-models) WITH_MODELS=1 ;;
    *) OUT="$arg" ;;
  esac
done
if [[ -z "$OUT" ]]; then
  OUT="$PARENT/ios_argmax-xtool-migration.tgz"
fi

EXCLUDES=(
  --exclude='.workbuddy'
  --exclude='.git'
  --exclude='.build'
  --exclude='build'
  --exclude='DerivedData'
  --exclude='Packages'
  --exclude='rustAPP'
  --exclude='xcuserdata'
  --exclude='.DS_Store'
  --exclude='._*'
  --exclude='*.pyc'
  --exclude='__pycache__'
  --exclude='xtool/dist'
  # Swift 6.2+ toolchains would prefer this upstream variant manifest, which
  # contains neither AutoTranscribeAI nor the xtool app product and forces
  # Swift 6 language mode. Keep Package.swift (tools 5.10, Swift 5 mode) as
  # the single manifest in the migration bundle.
  --exclude='Package@swift-6.2.swift'
)
if [[ "$WITH_MODELS" -eq 0 ]]; then
  EXCLUDES+=(
    --exclude='*.onnx'
    --exclude='*.gguf'
    --exclude='*.mlmodelc'
    --exclude='*.mlpackage'
    --exclude='*.mlmodel'
    --exclude='*.safetensors'
    --exclude='*.bin'
    --exclude='*.zip'
    --exclude='*.tar.gz'
    --exclude='*.part'
  )
fi

echo "Repository : $REPO"
echo "Output     : $OUT"
echo "With models: $WITH_MODELS"
cd "$PARENT"
COPYFILE_DISABLE=1 tar -czf "$OUT" "${EXCLUDES[@]}" "$NAME"

LIST="$(tar -tzf "$OUT")"
echo "=== required files in bundle ==="
for rel in \
  Package.swift \
  Package.resolved \
  xtool.yml \
  xtool/Info.plist \
  xtool/prepare_models.py \
  xtool/make_migration_pack.sh \
  xtool/USAGE.txt \
  Examples/AutoTranscribe/AutoTranscribe.xcodeproj/project.pbxproj \
  Examples/AutoTranscribe/AutoTranscribe/AutoTranscribeApp.swift \
  Examples/AutoTranscribe/AutoTranscribeAI/BundledResources.swift \
  Examples/AutoTranscribe/AutoTranscribe/Models/ai-models/.gitkeep \
  .github/workflows/ios-autotranscribe.yml; do
  if printf '%s\n' "$LIST" | grep -Fq "$NAME/$rel"; then
    echo "  OK      $rel"
  else
    echo "  MISSING $rel" >&2
    exit 1
  fi
done

echo "=== bundle ==="
ls -lh "$OUT"
printf 'entries: '; printf '%s\n' "$LIST" | wc -l
