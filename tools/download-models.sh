#!/usr/bin/env bash
# Unduh semua model AI ke folder "models" (sekali saja, ±2,9 GB). Jalankan lagi untuk melanjutkan bila terputus.
set -euo pipefail
cd "$(dirname "$0")/.."
HF=https://huggingface.co
QWEN=Qwen3.5-2B-q4f16_1-MLC
QDIR="models/$QWEN/resolve/main"

get() { # url dest
  [ -s "$2" ] && return 0
  mkdir -p "$(dirname "$2")"
  echo "  - ${2#models/}"
  curl -L --fail --retry 10 --retry-all-errors --retry-delay 2 -C - -o "$2.part" "$1"
  mv "$2.part" "$2"
}

for f in config.json generation_config.json preprocessor_config.json tokenizer.json tokenizer_config.json \
         added_tokens.json special_tokens_map.json normalizer.json vocab.json merges.txt; do
  get "$HF/onnx-community/whisper-large-v3-turbo/resolve/main/$f" "models/whisper-large-v3-turbo/$f"
  get "$HF/onnx-community/whisper-base/resolve/main/$f" "models/whisper-base/$f"
done
get "$HF/onnx-community/whisper-large-v3-turbo/resolve/main/onnx/encoder_model_fp16.onnx" models/whisper-large-v3-turbo/onnx/encoder_model_fp16.onnx
get "$HF/onnx-community/whisper-large-v3-turbo/resolve/main/onnx/decoder_model_merged_q4f16.onnx" models/whisper-large-v3-turbo/onnx/decoder_model_merged_q4f16.onnx
get "$HF/onnx-community/whisper-base/resolve/main/onnx/encoder_model.onnx" models/whisper-base/onnx/encoder_model.onnx
get "$HF/onnx-community/whisper-base/resolve/main/onnx/decoder_model_merged_quantized.onnx" models/whisper-base/onnx/decoder_model_merged_quantized.onnx
for f in mlc-chat-config.json tensor-cache.json tokenizer.json tokenizer_config.json vocab.json merges.txt; do
  get "$HF/mlc-ai/$QWEN/resolve/main/$f" "$QDIR/$f"
done
get https://raw.githubusercontent.com/mlc-ai/binary-mlc-llm-libs/main/web-llm-models/v0_2_86/base/Qwen3.5-2B-q4f16_1_cs1k-webgpu.wasm \
    models/libs/Qwen3.5-2B-q4f16_1_cs1k-webgpu.wasm
for s in $(grep -o '"dataPath": *"[^"]*"' "$QDIR/tensor-cache.json" | sed 's/.*"\([^"]*\)"$/\1/' | sort -u); do
  get "$HF/mlc-ai/$QWEN/resolve/main/$s" "$QDIR/$s"
done
echo "Model lengkap: $(du -sh models | cut -f1)"
