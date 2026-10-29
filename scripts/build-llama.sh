#!/bin/zsh
# Builds the llama-server that runs downloaded translation models: one static
# arm64 executable with the Metal shaders embedded and no web UI.
set -euo pipefail
cd "${0:A:h:h}"
llama_tag=b11981
llama_commit=da6c30ade8c30930dbf49fe57f9f02d727e99b15
llama_out=build/llama
if [[ -x $llama_out/llama-server && "$(cat $llama_out/commit 2>/dev/null)" == $llama_commit ]]; then exit 0; fi
llama_src=build/llama-src
rm -rf $llama_src
git -c advice.detachedHead=false clone --quiet --depth 1 --branch $llama_tag https://github.com/ggml-org/llama.cpp.git $llama_src
if [[ "$(git -C $llama_src rev-parse HEAD)" != $llama_commit ]]; then
  print -u2 "llama.cpp $llama_tag is not the pinned commit $llama_commit"
  exit 1
fi
cmake -S $llama_src -B $llama_src/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DGGML_RPC=OFF -DGGML_BLAS=OFF \
  -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF -DLLAMA_BUILD_APP=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_OSX_ARCHITECTURES=arm64 >/dev/null
cmake --build $llama_src/build --config Release -j "$(sysctl -n hw.ncpu)" --target llama-server >/dev/null
mkdir -p $llama_out
strip -x -o $llama_out/llama-server $llama_src/build/bin/llama-server
cp $llama_src/LICENSE $llama_out/LICENSE
print $llama_commit > $llama_out/commit
