#!/bin/sh
# Builds the fixture app and library with bin/apkbuild and checks the artifacts.
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
#
#   bash test/smoke.sh                  # uses the default SDK discovery
#   ANDROID_HOME=/opt/android-sdk bash test/smoke.sh
#
# This is the tool's contract test: an APK that installs and runs, and an AAR
# whose classes.jar can be dexed on its own and whose R.txt names its resource.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
apkbuild=$root/bin/apkbuild
work=$(mktemp -d "${TMPDIR:-/tmp}/apkbuild-smoke.XXXXXX")
# shellcheck disable=SC2064
trap "rm -rf '$work'" EXIT

echo "== doctor"
"$apkbuild" doctor

echo "== apk"
"$apkbuild" apk \
    --manifest "$root/test/fixture/AndroidManifest.xml" \
    --sources "$root/test/fixture/src" \
    --res "$root/test/fixture/res" \
    --out "$work/fixture.apk" \
    --min-sdk 24 --version-code 7 --version-name 1.2.3

python3 - "$work/fixture.apk" <<'PY'
import sys, zipfile
apk = zipfile.ZipFile(sys.argv[1])
names = set(apk.namelist())
for want in ('AndroidManifest.xml', 'classes.dex', 'resources.arsc'):
    if want not in names:
        sys.exit(f"APK is missing {want}: {sorted(names)}")
if not any(n.startswith('META-INF/') for n in names):
    sys.exit("APK is not signed: no META-INF signature files")
print(f"apk entries: {len(names)}")
PY
apksigner verify "$work/fixture.apk"

echo "== aar"
"$apkbuild" aar \
    --manifest "$root/test/fixture-lib/AndroidManifest.xml" \
    --sources "$root/test/fixture-lib/src" \
    --res "$root/test/fixture-lib/res" \
    --out "$work" \
    --group io.github.mbanucu --artifact apkbuild-fixture --version 0.1.0 \
    --pom --javadoc \
    --description "apkbuild contract fixture" \
    --url "https://github.com/MBanucu/termux-apkbuild"

python3 - "$work/apkbuild-fixture-0.1.0.aar" "$work/apkbuild-fixture-0.1.0.pom" <<'PY'
import io, sys, zipfile
aar = zipfile.ZipFile(sys.argv[1])
names = set(aar.namelist())
for want in ('AndroidManifest.xml', 'classes.jar', 'R.txt', 'res/values/strings.xml'):
    if want not in names:
        sys.exit(f"AAR is missing {want}: {sorted(names)}")
if not aar.read('R.txt').strip():
    sys.exit("AAR has an empty R.txt")
classes = zipfile.ZipFile(io.BytesIO(aar.read('classes.jar')))
if 'com/example/apkbuildlib/Greeting.class' not in classes.namelist():
    sys.exit("AAR classes.jar does not contain Greeting.class")
if 'com/example/apkbuildlib/R.class' not in classes.namelist():
    sys.exit("AAR classes.jar does not contain the generated R.class")
with open(sys.argv[2], encoding='utf-8') as f:
    pom = f.read()
for want in ('<artifactId>apkbuild-fixture</artifactId>', '<version>0.1.0</version>',
             '<packaging>aar</packaging>'):
    if want not in pom:
        sys.exit(f"POM is missing {want}")
print(f"aar entries: {len(names)}")
PY

echo "OK: apk, aar, pom and javadoc built"
