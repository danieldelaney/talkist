#!/usr/bin/env bash
# Downloads the Parakeet TDT 0.6B v2 (int8) model into ~/.local/share/talkist
set -euo pipefail
dest="${HOME}/.local/share/talkist"
mkdir -p "$dest"
cd "$dest"
curl -SsL -O https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2
tar xf sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2
rm sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2
ls -lh sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/
