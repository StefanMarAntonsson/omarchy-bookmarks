#!/usr/bin/env bash
# Installs the bookmark worker for this exact plugin revision.
#
# By default it downloads the release pinned in worker-release.pin and installs
# it only if its SHA-256 matches the hash committed in this plugin, so the
# reviewed commit fixes exactly which binary can run. When no release is
# pinned, or the download cannot be verified, it builds the plugin's own locked
# source with cargo instead. Nothing is ever run from an unverified download.
#
#   install-worker.sh [--from-source] [--pause]
#
#   --from-source  skip the release and build this checkout (for development)
#   --pause        wait for a key before exiting, for a terminal that closes

set -euo pipefail
umask 077

readonly repository="StefanMarAntonsson/omarchy-bookmarks"
readonly asset_prefix="omarchy-bookmarks-worker"
readonly max_binary_bytes=$((64 * 1024 * 1024))

plugin_dir=$(CDPATH='' cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
from_source=false
pause=false
for argument in "$@"; do
  case $argument in
    --from-source) from_source=true ;;
    --pause) pause=true ;;
    *) echo "Unknown option: $argument" >&2; exit 2 ;;
  esac
done

staging=""
finish() {
  local status=$?
  [[ -z $staging ]] || rm -rf -- "$staging"
  if [[ $pause == true ]]; then
    echo
    read -r -n 1 -s -p "Press any key to close." || true
    echo
  fi
  exit "$status"
}
trap finish EXIT

fail() {
  echo >&2
  echo "$1" >&2
  echo "The worker was not changed." >&2
  exit 1
}

absolute_or() {
  if [[ ${1:-} == /* ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

data_home=$(absolute_or "${XDG_DATA_HOME:-}" "$HOME/.local/share")
cache_home=$(absolute_or "${XDG_CACHE_HOME:-}" "$HOME/.cache")
app_dir="$data_home/stefanmara.bookmarks"
install_dir="$app_dir/bin"
binary="$install_dir/$asset_prefix"
record="$install_dir/$asset_prefix.record"
target_dir="$cache_home/stefanmara.bookmarks/target"

for tool in sha256sum flock; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed."
done

# The install location must be real directories owned by this user, never
# links that could redirect the write somewhere else.
for directory in "$app_dir" "$install_dir"; do
  [[ -L $directory ]] && fail "Refusing to install through a symlink: $directory"
  mkdir -p -- "$directory"
  [[ -O $directory ]] || fail "Install directory is not owned by you: $directory"
  chmod 700 -- "$directory"
done
[[ -L $binary || -L $record ]] && fail "Refusing to replace a symlinked worker in $install_dir"

lock="$app_dir/.install.lock"
[[ -L $lock ]] && fail "Refusing to use a symlinked lock: $lock"
exec 9>"$lock"
flock -n 9 || fail "Another worker setup is already running."

manifest_version=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([0-9][0-9A-Za-z.+-]*\)".*/\1/p' \
  "$plugin_dir/manifest.json" | head -n 1)
[[ -n $manifest_version ]] || fail "Could not read the plugin version from manifest.json."
source_id=$("$plugin_dir/scripts/worker-source-id.sh" "$plugin_dir")

pin_value() {
  sed -n "s/^$1=\\([0-9A-Za-z.+-]*\\)\$/\\1/p" "$plugin_dir/worker-release.pin" | head -n 1
}

staging=$(mktemp -d "$install_dir/.staging.XXXXXX")
candidate="$staging/$asset_prefix"
origin=""

download_release() {
  local architecture expected actual version pinned_source url

  version=$(pin_value version)
  pinned_source=$(pin_value source)
  if [[ $version != "$manifest_version" || ! $pinned_source =~ ^[0-9a-f]{64}$ ]]; then
    echo "No worker release is pinned for version $manifest_version."
    return 1
  fi
  if [[ $pinned_source != "$source_id" ]]; then
    echo "This checkout's worker source differs from the pinned release."
    return 1
  fi
  architecture=$(uname -m)
  case $architecture in
    x86_64|aarch64) ;;
    *) echo "No worker release is published for $architecture."; return 1 ;;
  esac
  expected=$(pin_value "$architecture")
  [[ $expected =~ ^[0-9a-f]{64}$ ]] || { echo "No hash is pinned for $architecture."; return 1; }
  command -v curl >/dev/null 2>&1 || { echo "curl is not installed."; return 1; }

  url="https://github.com/$repository/releases/download/v$version/$asset_prefix-$architecture"
  echo "Downloading worker $version for $architecture"
  if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fL --progress-bar \
      --connect-timeout 10 --max-time 300 --retry 2 --max-filesize "$max_binary_bytes" \
      -o "$candidate" "$url"; then
    echo "The download failed."
    return 1
  fi
  if (( $(stat -c %s -- "$candidate") > max_binary_bytes )); then
    echo "The download exceeded the size limit."
    return 1
  fi
  actual=$(sha256sum -- "$candidate" | cut -d ' ' -f 1)
  if [[ $actual != "$expected" ]]; then
    echo "WARNING: the download does not match the hash pinned in this plugin. It was discarded."
    rm -f -- "$candidate"
    return 1
  fi
  echo "Verified SHA-256 $actual"
  origin=release
}

build_from_source() {
  command -v cargo >/dev/null 2>&1 \
    || fail "cargo is not installed, so the worker cannot be built from source. Install Rust (for example with: mise use -g rust) and run setup again."
  echo "Building the worker from this plugin's source"
  # Build outside the plugin directory: Omarchy reloads a plugin whenever a
  # file inside it changes, which would interrupt the build.
  CARGO_TARGET_DIR="$target_dir" cargo build --locked --release \
    --manifest-path "$plugin_dir/Cargo.toml" || fail "The build failed."
  [[ $("$plugin_dir/scripts/worker-source-id.sh" "$plugin_dir") == "$source_id" ]] \
    || fail "The worker source changed during the build. Run setup again."
  cp -- "$target_dir/release/$asset_prefix" "$candidate"
  origin=source
}

if [[ $from_source == true ]] || ! download_release; then
  [[ $from_source == true ]] || echo "Falling back to a source build."
  build_from_source
fi

chmod 700 -- "$candidate"
reported=$(timeout 10 "$candidate" --version 2>/dev/null || true)
[[ $reported == "$asset_prefix $manifest_version" ]] \
  || fail "The new worker reported '${reported:-nothing}' instead of version $manifest_version."

hash=$(sha256sum -- "$candidate" | cut -d ' ' -f 1)
printf 'origin=%s\nversion=%s\nsource=%s\nsha256=%s\n' \
  "$origin" "$manifest_version" "$source_id" "$hash" > "$staging/record"
mv -f -- "$candidate" "$binary"
mv -f -- "$staging/record" "$record"

echo
echo "Worker $manifest_version installed ($origin): $binary"
echo "If Bookmarks opened this setup, close the terminal to return to it."
