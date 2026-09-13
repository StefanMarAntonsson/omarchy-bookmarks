#!/bin/sh
set -eu

plugin_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
local_binary="$plugin_dir/target/release/omarchy-bookmarks-worker"
installed_binary="${XDG_DATA_HOME:-$HOME/.local/share}/stefanmara.bookmarks/bin/omarchy-bookmarks-worker"

if [ -x "$local_binary" ]; then
  exec "$local_binary"
fi
if [ -x "$installed_binary" ]; then
  exec "$installed_binary"
fi

echo '{"version":1,"id":0,"ok":false,"error":"Rust worker is not installed. Run cargo build --release in the plugin directory."}'
exit 127

