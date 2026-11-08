#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OUT=${1:-"$ROOT/.build/utm-qemu-launcher"}
SDK=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p "$(dirname -- "$OUT")"
clang -Wall -Wextra -O2 -mmacosx-version-min=14.0 -isysroot "$SDK" \
  "$ROOT/Tools/utm-qemu-launcher/main.c" -ldl \
  -Wl,-rpath,@executable_path/../Frameworks -o "$OUT"
printf '%s\n' "$OUT"
