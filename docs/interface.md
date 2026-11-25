# Interface v1

This is the contract consumers pin. Additive changes are allowed within v1; a
removed flag or a changed default is v2.

## Commands

| Command | Does | Required |
| --- | --- | --- |
| `doctor` | Prints the resolved SDK, tools and Java level. | — |
| `sdk` | Prints `ANDROID_HOME`, `ANDROID_JAR`, `ANDROID_API`, `BUILD_TOOLS` as `key=value`. | — |
| `compile` | `javac` source directories into a classes directory. | `--sources`, `--out` |
| `link` | `aapt2 compile` + `aapt2 link` a manifest into an APK base. | `--manifest`, `--out` |
| `dex` | `d8` a jar or classes directory. | `--in`, `--out` |
| `package` | Copies an APK base, adds `classes*.dex` and optional `lib/`. | `--base`, `--dex`, `--out` |
| `sign` | `zipalign` + `apksigner`. | `--in`, `--out` |
| `apk` | The whole pipeline: link, compile, dex, package, sign. | `--manifest`, `--sources`, `--out` |
| `aar` | A library AAR, sources jar, optional javadoc and POM. | `--manifest`, `--sources`, `--out`, coordinates |

### Common options

- `--min-sdk N` (default `24`) and `--target-sdk N` (default: platform).
- `--version-code N` (default `1`), `--version-name S` (default `1.0`).
- `--release N` (default `JAVA_RELEASE`, then `17`).
- `--classpath PATH` may be repeated; entries are joined with `:`.
- `--res DIR` compiles and links resources. An AAR with resources is linked
  with `aapt2 link --static-lib` and carries the original `res/` plus `R.txt`.
- `--assets DIR`, `--jni DIR` (APK only). JNI is compiled for `--abi`
  (default `arm64-v8a`) with `clang --target=<abi>-linux-android<minSdk>`; the
  library is named after the directory, so `native-terminal` becomes
  `libnative_terminal.so`.
- `--pom`, `--javadoc`, `--description`, `--url`, `--license-name`,
  `--license-url`, `--dependency G:A:V` (AAR only).

## Resolution

1. `ANDROID_JAR` if set; otherwise the SDK from `ANDROID_HOME`,
   `ANDROID_SDK_ROOT`, `~/android-sdk`, `/usr/lib/android-sdk`, and the platform
   `ANDROID_API` or the newest installed.
2. `aapt2`/`d8`/`zipalign`/`apksigner`: explicit variable, then `PATH`, then
   `<build-tools>/<tool>`.
3. Signing: `--keystore`/`--store-password`/`--key-alias`/`--key-password`, then
   `KEYSTORE`/`KEYSTORE_PASSWORD`/`KEY_ALIAS`/`KEY_PASSWORD`. With none set, a
   debug key is created at `~/.android/debug.keystore`.

## Output layout

```
<out>/<artifact>-<version>.aar          classes.jar, AndroidManifest.xml, R.txt, res/
<out>/<artifact>-<version>.jar          the same classes, for a test classpath
<out>/<artifact>-<version>-sources.jar
<out>/<artifact>-<version>-javadoc.jar  only with --javadoc
<out>/<artifact>-<version>.pom          only with --pom
```

The intermediate work directory is under `TMPDIR` and is removed on exit,
including on failure. The keystore is never written under the output directory.

## Failures

`set -euo pipefail` is on. A missing SDK, platform, tool, manifest, source
directory or keystore is a non-zero exit with one line naming the missing thing
and the install/override that fixes it. Commands do not continue past a failed
step, and no partial artifact is reported as built.
