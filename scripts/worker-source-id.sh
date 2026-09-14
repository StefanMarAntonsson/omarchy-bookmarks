#!/bin/sh
# Prints one SHA-256 that identifies the worker's Rust source: Cargo.toml,
# Cargo.lock, and every .rs file under src/. The launcher, setup, and release
# pinning all use this, so a binary is only ever run for the exact source it
# was built or released from.
#
#   worker-source-id.sh [plugin-directory]

set -eu
export LC_ALL=C

root=${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
cd -- "$root"

{
  sha256sum -- Cargo.toml Cargo.lock
  find src -type f -name '*.rs' | sort | while IFS= read -r file; do
    sha256sum -- "$file"
  done
} | sha256sum | cut -d ' ' -f 1
