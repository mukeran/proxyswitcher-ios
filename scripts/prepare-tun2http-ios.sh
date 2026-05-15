#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBMODULE_DIR="$ROOT_DIR/third_party/proxyswitcher-tun2http"
OUTPUT_LIB="$ROOT_DIR/Tunnel/libproxyswitcher_tun2http.a"
OUTPUT_HEADER="$ROOT_DIR/Tunnel/proxyswitcher_tun2http.h"

if [[ ! -d "$SUBMODULE_DIR" ]]; then
  echo "submodule missing: $SUBMODULE_DIR" >&2
  exit 1
fi

pushd "$SUBMODULE_DIR" >/dev/null
./scripts/build-ios.sh
cp -f "$SUBMODULE_DIR/build/ios/device/libproxyswitcher_tun2http.a" "$OUTPUT_LIB"
cp -f "$SUBMODULE_DIR/include/proxyswitcher_tun2http.h" "$OUTPUT_HEADER"
popd >/dev/null

echo "Prepared $OUTPUT_LIB"
