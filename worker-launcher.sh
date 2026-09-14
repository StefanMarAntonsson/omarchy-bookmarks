#!/bin/sh
# Starts the bookmark worker installed by scripts/install-worker.sh, but only
# when it was installed for this plugin's exact worker source and has not been
# changed since. Otherwise it reports that setup is needed and runs nothing.

set -eu

plugin_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
case ${XDG_DATA_HOME:-} in
  /*) data_home=$XDG_DATA_HOME ;;
  *) data_home=$HOME/.local/share ;;
esac
install_dir="$data_home/stefanmara.bookmarks/bin"
binary="$install_dir/omarchy-bookmarks-worker"
record="$install_dir/omarchy-bookmarks-worker.record"

setup_required() {
  printf '{"version":1,"id":0,"ok":false,"code":"worker_setup_required","error":"%s"}\n' "$1"
  exit 78
}

record_value() {
  sed -n "s/^$1=\\([0-9a-f]*\\)\$/\\1/p" "$record" | head -n 1
}

if [ ! -f "$binary" ] || [ -L "$binary" ] || [ ! -x "$binary" ] \
    || [ ! -f "$record" ] || [ -L "$record" ]; then
  setup_required "The bookmark worker is not installed yet."
fi

expected_hash=$(record_value sha256)
expected_source=$(record_value source)
actual_source=$("$plugin_dir/scripts/worker-source-id.sh" "$plugin_dir")
if [ -z "$expected_source" ] || [ "$expected_source" != "$actual_source" ]; then
  setup_required "The bookmark worker needs to be set up for this plugin version."
fi
actual_hash=$(sha256sum < "$binary" | cut -d ' ' -f 1)
if [ -z "$expected_hash" ] || [ "$expected_hash" != "$actual_hash" ]; then
  setup_required "The installed bookmark worker was changed and must be set up again."
fi

exec "$binary"
