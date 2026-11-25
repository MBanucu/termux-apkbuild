# termux-apkbuild

One Gradle-free Android build for the phone jobs in this workspace. It replaces
copies of the same script that had drifted in five repositories:

| Repository | Script | Lines |
| --- | --- | --- |
| android-accessible-terminal | `samples/build.sh` | 243 |
| screenstream | `build.sh` | 226 |
| opencode-termux-setup | `samples/build.sh` | 181 |
| wireless-adb-keeper | `build.sh` | 60 |
| termux-adb-bridge | `build.sh` | 47 |

Every copy rediscovered `android.jar`, preferred Termux's bionic `aapt2`/`d8`
over the SDK's glibc builds, ran `aapt2 link`/`javac`/`d8`, packaged the dex and
signed with a keystore kept outside the output. This repository is that work
once, with a versioned interface.

It is not a Gradle replacement for normal development. It is the path that works
on the phone, offline, with no dependency resolution.

## Quick start

```sh
# What did it resolve?
bin/apkbuild doctor

# An APK
bin/apkbuild apk \
  --manifest app/AndroidManifest.xml \
  --sources app/src \
  --res app/res \
  --out out/app.apk

# A library, with Maven metadata for publish.sh or a Central bundle
bin/apkbuild aar \
  --manifest lib/AndroidManifest.xml \
  --sources lib/src \
  --res lib/res \
  --out out \
  --group io.github.mbanucu --artifact my-library --version 0.1.0 \
  --pom --javadoc --description "What it is"
```

The APK is zipaligned and signed with the debug key unless `KEYSTORE` (or
`--keystore`) names another one. The AAR build writes `.aar`, `.jar`,
`-sources.jar`, optionally `-javadoc.jar` and `.pom`.

## How a consumer uses it

Two supported routes, both pinned by tag:

- vendor `bin/apkbuild` and `lib/apkbuild.sh` into the consumer, or
- add this repository as a submodule and call `termux-apkbuild/bin/apkbuild`.

The interface in [docs/interface.md](docs/interface.md) is frozen for v1. The
tool writes only under the paths it is given, plus a temporary directory it
removes on exit.

## Environment

`ANDROID_HOME` / `ANDROID_SDK_ROOT` / `~/android-sdk` is searched for the SDK;
`ANDROID_API` selects the platform (default: newest installed), `BUILD_TOOLS`
the build-tools version. `ANDROID_JAR` overrides both for a host with no SDK.

`aapt2`, `d8`, `zipalign` and `apksigner` are looked up in this order: explicit
`AAPT2`/`D8`/`ZIPALIGN`/`APKSIGNER`, then `PATH` (Termux's native packages),
then the SDK's build-tools. That order is deliberate: on Termux the SDK binaries
are x86_64/glibc and cannot execute.

## Verify

```sh
bash test/smoke.sh
```

It builds a fixture APK and AAR with the tool itself, verifies the APK signature
and the AAR layout, extracts the generated `R.class` from `classes.jar`, and
checks the POM coordinates. The same script runs in CI on Ubuntu with an SDK, so
the Linux fallback is exercised too.

## Status

Consumers still run their local copies. The migration roadmap is
[screenstream#7](https://github.com/MBanucu/screenstream/issues/7); the tool is
usable and tested, but "one pinned tool in all five repos" is not claimed until
those copies are deleted.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
