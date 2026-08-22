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

if [ -e "$data_path" ] || [ -L "$data_path" ]; then
  if [ ! -f "$data_path" ] || [ -L "$data_path" ]; then
    echo "bookmark store path must be a regular file" >&2
    exit 1
  fi
  printf existing
  exit 0
fi

temp_path=$(mktemp -p "$data_dir" ".bookmarks.json.init.XXXXXX")
trap 'rm -f -- "$temp_path"' EXIT HUP INT TERM

printf '{"version":3,"bookmarks":[]}\n' >"$temp_path"

mv -T -- "$temp_path" "$data_path"
trap - EXIT HUP INT TERM
printf created
