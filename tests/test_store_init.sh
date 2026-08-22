#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
initializer="$project_root/bookmark_store_init.sh"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM

data_dir="$test_root/data/stefanmara.bookmarks"
data_path="$data_dir/bookmarks.json"

result=$(sh "$initializer" "$data_dir" "$data_path")
[ "$result" = created ]
[ "$(cat "$data_path")" = '{"version":3,"bookmarks":[]}' ]
[ "$(stat -c %a "$data_dir")" = 700 ]
[ "$(stat -c %a "$data_path")" = 600 ]

printf '{"version":3,"bookmarks":[{"url":"https://preserved.example"}]}\n' >"$data_path"
result=$(sh "$initializer" "$data_dir" "$data_path")
[ "$result" = existing ]
grep -q preserved.example "$data_path"

legacy_home="$test_root/home"
legacy_path="$legacy_home/.config/omarchy/bookmarks.json"
fresh_data_dir="$test_root/fresh-data/stefanmara.bookmarks"
fresh_data_path="$fresh_data_dir/bookmarks.json"
mkdir -p "$(dirname "$legacy_path")"
printf '{"version":3,"bookmarks":[{"url":"https://legacy.example"}]}\n' >"$legacy_path"

result=$(HOME="$legacy_home" sh "$initializer" "$fresh_data_dir" "$fresh_data_path")
[ "$result" = created ]
[ "$(cat "$fresh_data_path")" = '{"version":3,"bookmarks":[]}' ]
grep -q legacy.example "$legacy_path"
