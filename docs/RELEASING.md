# Releasing

The worker executable is never committed. Releases are built from a version tag
by GitHub Actions, attested, and then pinned into the plugin by hash, so the
commit a reviewer approves fixes exactly which executable users can install.

## 1. Prepare

1. Set the same version in `manifest.json`, `Cargo.toml`, and
   `worker-release.pin` (`version=`), and update `Cargo.lock` with
   `cargo update --workspace` or a build.
2. Clear the pin's `source`, `x86_64`, and `aarch64` values; step 3 fills
   them in.
3. Run `./tests/run`.
4. Optional: run **Release worker** manually from the Actions tab. A manual run
   builds and tests both architectures but never attests or publishes.
5. Commit and push.

## 2. Tag and publish

```bash
git tag v2.0.0
git push origin v2.0.0
```

The tag starts `.github/workflows/release.yml`, which:

- refuses a tag that does not equal `v<manifest version>` or a Cargo version
  that differs from the manifest;
- tests, then builds static musl executables with a pinned Rust toolchain on
  GitHub-hosted x86_64 and aarch64 runners;
- rejects an executable that reports the wrong version or links dynamically;
- creates GitHub build attestations for each executable and `SHA256SUMS`;
- publishes `omarchy-bookmarks-worker-x86_64`,
  `omarchy-bookmarks-worker-aarch64`, and `SHA256SUMS`.

Every action is pinned to a commit. Never move or reuse a tag; fix a failed
release with a new version.

## 3. Pin

```bash
scripts/pin-worker-release.sh
```

It refuses unless the checkout's worker source (`Cargo.toml`, `Cargo.lock`,
`src/`) is identical to the tag, the checksums match, and each executable's
attestation was produced by this repository's release workflow at that tag and
commit on a GitHub-hosted runner. It then writes the hashes and source
fingerprint to `worker-release.pin`.

Commit `worker-release.pin` (the only change) and push. Submit that commit to
the marketplace, with links to the release and workflow run so the reviewer can
repeat the verification in the README.

## Between releases

Changing any worker source makes the pinned release stop matching. Users of
such a commit get a source build, and your own overlay asks for setup until you
run `scripts/install-worker.sh --from-source`. QML-only changes keep using the
pinned release. Release a new version before submitting a commit that changes
the worker.
