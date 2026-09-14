#!/usr/bin/env bash
# Pins a published worker release into worker-release.pin. Maintainer tool;
# the plugin never runs this.
#
# It requires that the release tag matches manifest.json, that this checkout's
# worker source is identical to the tagged source, and that every executable
# carries a GitHub build attestation from this repository's release workflow at
# that tag and commit, built on a GitHub-hosted runner. Only then are the
# hashes written.
#
#   pin-worker-release.sh

set -euo pipefail
export LC_ALL=C

readonly repository="StefanMarAntonsson/omarchy-bookmarks"
readonly workflow=".github/workflows/release.yml"
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd -- "$root"

for tool in gh git sha256sum python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required." >&2; exit 1; }
done

version=$(python3 -c 'import json; print(json.load(open("manifest.json"))["version"])')
tag="v$version"
git fetch --quiet origin "refs/tags/$tag:refs/tags/$tag"
commit=$(git rev-parse "$tag^{commit}")

if ! git diff --quiet "$tag" -- Cargo.toml Cargo.lock src \
    || [[ -n $(git status --porcelain --untracked-files=all -- Cargo.toml Cargo.lock src) ]]; then
  echo "The worker source differs from $tag. Release a new version instead." >&2
  exit 1
fi
source_id=$(scripts/worker-source-id.sh)

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
gh release download "$tag" --repo "$repository" --dir "$work" \
  --pattern SHA256SUMS --pattern 'omarchy-bookmarks-worker-*'
(cd "$work" && sha256sum --check --strict SHA256SUMS)

declare -A hashes
for architecture in x86_64 aarch64; do
  asset="$work/omarchy-bookmarks-worker-$architecture"
  gh attestation verify "$asset" \
    --repo "$repository" \
    --cert-identity "https://github.com/$repository/$workflow@refs/tags/$tag" \
    --source-ref "refs/tags/$tag" \
    --source-digest "$commit" \
    --deny-self-hosted-runners >/dev/null
  hashes[$architecture]=$(sha256sum -- "$asset" | cut -d ' ' -f 1)
  echo "Verified $architecture ${hashes[$architecture]}"
done

temporary=$(mktemp worker-release.pin.XXXXXX)
{
  sed -n '/^#/p' worker-release.pin
  printf 'version=%s\nsource=%s\nx86_64=%s\naarch64=%s\n' \
    "$version" "$source_id" "${hashes[x86_64]}" "${hashes[aarch64]}"
} > "$temporary"
chmod 644 "$temporary"
mv -f -- "$temporary" worker-release.pin

echo
echo "Pinned $tag ($commit). Commit worker-release.pin and submit that commit."
