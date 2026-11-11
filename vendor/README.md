# vendor/ — patched upstream artifacts

## TEESimulator-RS-v6.1.0-315-Release.zip

A patched build of the TEE-Simulator-RS attestation engine that `build.sh` bundles
by default for the `tee` engine (the stock release is no longer downloaded unless
you pass `--tee-file` or `--engine teesim|trickystoreoss`).

**Base:** upstream `Enginex0/TEESimulator-RS` tag `v6.0.1-307` (== `main` HEAD;
upstream has not merged to main since 2026-07-11).

**Cherry-picked open PRs** (none are in the upstream release):

| PR | Fix |
|----|-----|
| #68 | Android 17 canary injection: `libbinder.so` is now a symlink to `libcore_bundle.so`; without this the `0xdeadbeef` hook is never installed and keystore2 crashes (module does not inject at all on A17 canary). |
| #73 | Android 17 / KeyMint v5 attestation correctness: `osVersion` 170000 on SDK 37, `attestVersion`/`keymasterVersion` 500, VINTF APEX-fragment scan, per-instance TEE/StrongBox VINTF, ML-DSA tolerance, EC-curve parse crash fix. Supersedes #69. |
| #63 | RSA cipher block-mode fix (`RSA/CBC/PKCS1Padding` NoSuchAlgorithmException). |
| #77 | Purge cached TEE responses on `clearNamespace` so a key survives an app "clear data" (was failing with KEY_NOT_FOUND). |
| #47 | Normalize Xiaomi/Redmi/Poco secure-boot aliases (`ro.secureboot.lockstate` etc.) so Key Attestation reports deviceLocked/Verified. |

**Additional fix** (not from an upstream PR):

| Commit | Fix |
|--------|-----|
| 0cfad42 | `toAuthorizations()` now emits `RSA_OAEP_MGF_DIGEST` in generateKey characteristics. Without this, apps checking key metadata on KeyMint 3+ (Android 14+) see missing MGF digest, which Duck Detector flags and banking apps reject. The earlier upstream fix (1f96c8a) only patched `createOperation`. |
| 5e81e09 | Keyboxes with a PKCS#8 private key (`BEGIN PRIVATE KEY`) are now accepted: the key used to be dropped, so generateKey failed with `-75 No usable attestation key in keybox.xml`. The public key is taken from the entry's attestation certificate. An empty keybox parse (missing file, read mid-write) is also no longer cached. |

Only `module/changelog.md` conflicted (two prepended entries); resolved as a union.
Net change vs upstream: 16 files, +354/-65, no code conflicts.

### Corresponding source (GPL-3.0)

TEESimulator-RS is GPL-3.0, so the exact source of the bundled binary ships with
it. It is upstream `Enginex0/TEESimulator-RS` at commit `6d241e5` (tag
`v6.0.1-307`) plus **`teesimulator-rs-v6.1.0-315.patch`** in this directory, the
combined diff of the five PRs above plus the MGF digest and PKCS#8 keybox fixes (16 files, +354/-65).
To get the full source the binary was built from:

```sh
git clone --recursive https://github.com/Enginex0/TEESimulator-RS teesim
cd teesim && git checkout 6d241e5
git apply /path/to/vendor/teesimulator-rs-v6.1.0-315.patch
```

Then build as below. The patch is the authoritative record; the PR list is for
provenance and can drift if upstream force-pushes or deletes a branch.

### Regenerating (WSL)

The Windows host can't build Android; WSL (Ubuntu) has the full toolchain
(JDK 21, Rust + android targets, cargo-ndk, Android SDK/NDK 27.3 at
`/home/muhammed/Android/Sdk`).

```sh
cd ~/build && git clone --recursive https://github.com/Enginex0/TEESimulator-RS teesim
cd teesim
for n in 68 63 77 73 47; do git fetch origin "pull/$n/head:pr-$n"; done
git checkout -B patched main
for n in 68 63 77 73 47; do
  git merge --squash "pr-$n" || true           # resolve module/changelog.md as a union
  git add -A && git commit -m "integrate upstream PR #$n"
done
export ANDROID_HOME=/home/muhammed/Android/Sdk
echo "sdk.dir=$ANDROID_HOME" > local.properties
./gradlew zipRelease -Dorg.gradle.jvmargs=-Xmx3072m --no-daemon --console=plain
# -> out/TEESimulator-RS-v6.1.0-<count>-Release.zip  (copy into vendor/)
```

Then drop the new zip in `vendor/` (build.sh auto-picks the newest
`TEESimulator-RS-*-Release.zip`) and remove the old one.

**Not flash-tested on a STRONG-capable device.** Build + source review only.
