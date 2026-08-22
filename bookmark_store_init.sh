#!/bin/sh

set -eu
umask 077

if [ "$#" -ne 2 ]; then
  echo "usage: bookmark_store_init.sh DATA_DIR DATA_PATH" >&2
  exit 2
fi

data_dir=$1
data_path=$2

mkdir -p -- "$data_dir"

if [ -e "$data_path" ]; then
  printf existing
  exit 0
fi

temp_path="$data_dir/.bookmarks.json.init.$$"
trap 'rm -f -- "$temp_path"' EXIT HUP INT TERM

printf '{"version":3,"bookmarks":[]}\n' >"$temp_path"

mv -- "$temp_path" "$data_path"
trap - EXIT HUP INT TERM
printf created
