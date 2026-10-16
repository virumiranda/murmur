#!/bin/bash
# Downloads a whisper.cpp model into ~/.config/murmur/models (or $MURMUR_CONFIG_DIR/models).
#
#   ./scripts/download-model.sh                              # large-v3-turbo-q5_0 (574 MB)
#   ./scripts/download-model.sh large-v3-turbo-q5_0 --coreml # + Neural Engine encoder (1.2 GB, ~3x faster encoding)
#   ./scripts/download-model.sh small                        # 466 MB, faster on old Macs, weaker on accents
#
# Then set "transcription.localModel" in config.json to the same name.
# With --coreml, the first load converts the encoder for the Neural Engine. That takes ~2 minutes, once.
set -euo pipefail

name="${1:-large-v3-turbo-q5_0}"
coreml="${2:-}"
case "$name" in
  tiny|tiny.en|base|base.en|small|small.en|medium|medium.en|large-v3|large-v3-turbo) ;;
  *-q5_0|*-q5_1|*-q8_0) ;;
  *) echo "Unknown model '$name'. Try: large-v3-turbo-q5_0, small, medium" >&2; exit 1 ;;
esac

dir="${MURMUR_CONFIG_DIR:-$HOME/.config/murmur}/models"
base="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
mkdir -p "$dir"

file="$dir/ggml-$name.bin"
if [ -s "$file" ]; then
  echo "Already have $file"
else
  echo "Downloading ggml-$name.bin"
  curl -L --fail --progress-bar -o "$file.part" "$base/ggml-$name.bin"
  mv "$file.part" "$file"
fi

if [ "$coreml" = "--coreml" ]; then
  encoder="ggml-${name%-q[0-9]_[0-9]}-encoder.mlmodelc"   # quantized models share the full model's encoder
  if [ -d "$dir/$encoder" ]; then
    echo "Already have $encoder"
  else
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    echo "Downloading $encoder (Neural Engine)"
    curl -L --fail --progress-bar -o "$tmp/encoder.zip" "$base/$encoder.zip"
    unzip -q "$tmp/encoder.zip" -d "$tmp/x"
    mv "$tmp/x/$encoder" "$dir/"
  fi
fi
echo "Done: $dir"
