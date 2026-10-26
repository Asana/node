#!/usr/bin/env bash
#
# Verifies an Asana Node.js build before it is published:
#   1. The binary only needs glibc/libstdc++ symbol versions available on Ubuntu 22.04,
#      the oldest platform that runs the LunaServer Node toolchain (sandboxes and EngFlow
#      remote-execution workers).
#   2. asana-smoke-test.js passes on stock Ubuntu 22.04 and on Wolfi, the base of the
#      LunaServer images.
#
# Usage: asana-verify-build.sh <node-install-dir> [--fips]
#
# <node-install-dir> is the DESTDIR passed to `make install`, i.e. it contains usr/local/bin/node.
# Requires docker and binutils.

set -euo pipefail

INSTALL_DIR=$(cd "$1" && pwd)
FLAVOR=${2:-}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NODE_BIN="$INSTALL_DIR/usr/local/bin/node"

MAX_GLIBC=2.35
MAX_GLIBCXX=3.4.30
MAX_CXXABI=1.3.13

SMOKE_ARGS=""
UBUNTU_PACKAGES=""
WOLFI_PACKAGES="libstdc++ libgcc"
if [ "$FLAVOR" = "--fips" ]; then
  SMOKE_ARGS="--fips"
  UBUNTU_PACKAGES="libssl3"
  WOLFI_PACKAGES="$WOLFI_PACKAGES libssl3 libcrypto3"
fi

test -x "$NODE_BIN" || { echo "ERROR: $NODE_BIN not found" >&2; exit 1; }

max_symbol_version() {
  objdump -T "$NODE_BIN" | grep -o "$1_[0-9][0-9.]*" | sed "s/^$1_//" | sort -uV | tail -1
}

check_symbol_version() {
  local prefix=$1 limit=$2 found
  found=$(max_symbol_version "$prefix")
  echo "Highest $prefix symbol version required: ${found:-none} (limit $limit)"
  if [ -n "$found" ] && [ "$(printf '%s\n%s\n' "$found" "$limit" | sort -V | tail -1)" != "$limit" ]; then
    echo "ERROR: node requires ${prefix}_$found, newer than ${prefix}_$limit on Ubuntu 22.04" >&2
    objdump -T "$NODE_BIN" | grep "${prefix}_$found" | head -20 >&2
    exit 1
  fi
}

echo "=== Dynamic dependencies ==="
objdump -p "$NODE_BIN" | grep NEEDED

echo "=== Symbol versions ==="
check_symbol_version GLIBC "$MAX_GLIBC"
check_symbol_version GLIBCXX "$MAX_GLIBCXX"
check_symbol_version CXXABI "$MAX_CXXABI"

run_smoke_test() {
  local image=$1 setup=$2
  echo "=== Smoke test on $image ==="
  docker run --rm \
    -v "$INSTALL_DIR:/opt/node:ro" \
    -v "$SCRIPT_DIR/asana-smoke-test.js:/opt/asana-smoke-test.js:ro" \
    "$image" \
    sh -c "set -e; $setup /opt/node/usr/local/bin/node /opt/asana-smoke-test.js $SMOKE_ARGS"
}

UBUNTU_SETUP=""
if [ -n "$UBUNTU_PACKAGES" ]; then
  UBUNTU_SETUP="apt-get update -qq && apt-get install -y -qq --no-install-recommends $UBUNTU_PACKAGES >/dev/null;"
fi
run_smoke_test ubuntu:22.04 "$UBUNTU_SETUP"
run_smoke_test cgr.dev/chainguard/wolfi-base "apk add --no-cache -q $WOLFI_PACKAGES;"

echo "=== Build verified ==="
