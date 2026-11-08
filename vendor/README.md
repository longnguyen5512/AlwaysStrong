# vendor/ — patched upstream artifacts

## TEESimulator-RS-v6.1.0-313-Release.zip

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

Only `module/changelog.md` conflicted (two prepended entries); resolved as a union.
Net change vs upstream: 14 files, +316/-61, no code conflicts.

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
