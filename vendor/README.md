# vendor/ — patched upstream artifacts

## TEESimulator-RS-v6.1.0-319-Release.zip

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
| 4ca8d6f, 05c3e28 | (from wfire06100/TEESimulator-RS 863c0b0, 99a97cf) RSA-OAEP MGF digest: deduplicated authorizations, SHA-1 default when the MGF digest is omitted, and the dedicated `UNSUPPORTED_MGF_DIGEST` / `INCOMPATIBLE_MGF_DIGEST` errors. |
| 530cd18 | (from wfire06100/TEESimulator-RS a486fa8, code only) Crypto audit: correct KeyMint ErrorCode values (e.g. `INCOMPATIBLE_PURPOSE` -3, `TOO_MANY_OPERATIONS` -31), AES-GCM tag length and nonce validation, HMAC MAC length checks, unsupported digests rejected instead of silently replaced with SHA-256, synchronized and fsynced key persistence. |
| bc9907d | An AIDL KeyMint `<hal>` without a `<version>` element now counts as version 1, like libvintf. It used to fall back to the SDK guess (200 on Android 13) while the device declared KeyMint v1 (100), which Duck Detector reports as a KeyMint VINTF mismatch (seen on a MediaTek mitee KeyMint). |

Conflicts: `module/changelog.md` (two prepended entries, resolved as a union) and the `RSA_OAEP_MGF_DIGEST` block of `toAuthorizations()` (0cfad42 vs 863c0b0, resolved to the deduplicating 863c0b0 version).
Net change vs upstream: 21 files, +499/-117.

### Corresponding source (GPL-3.0)

TEESimulator-RS is GPL-3.0, so the exact source of the bundled binary ships with
it. It is upstream `Enginex0/TEESimulator-RS` at commit `6d241e5` (tag
`v6.0.1-307`) plus **`teesimulator-rs-v6.1.0-319.patch`** in this directory, the
combined diff of the five PRs above plus the MGF digest, PKCS#8 keybox, crypto-audit and VINTF fixes (21 files, +499/-117).
To get the full source the binary was built from:

```sh
git clone --recursive https://github.com/Enginex0/TEESimulator-RS teesim
cd teesim && git checkout 6d241e5
git apply /path/to/vendor/teesimulator-rs-v6.1.0-319.patch
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

### Local Android 17 Keystore2 patch (`teesimulator-rs-android17-keystore2.patch`)

Applied on top of `TEESimulator-RS-v6.1.0-319-Release.zip` (`classes.dex` updated inside the archive):
- `Keystore2Interceptor.kt`: stop rewriting real `keystore2` `EX_SERVICE_SPECIFIC` replies via `normalizeServiceSpecificReply()` in `onPostTransact`, and skip rebuilding `getNumberOfEntries` replies when `softwareCount == 0`.
- `InterceptorUtils.kt`: align `synthesizeSseMessage(7)` with Android 17 `keystore2`'s Rust error format (`Error::Rc(r#KEY_NOT_FOUND)`) and map `6` to `Error::Rc(r#PERMISSION_DENIED)`.

**Not flash-tested on a STRONG-capable device.** Build + source review only.
