# shellcheck shell=bash
# lib/apkbuild.sh -- the implementation behind bin/apkbuild.
#
# Sourced, never executed. Every command is a function so a consumer that
# vendors this file can also call one step on its own.
#
# The tool deliberately has no Gradle and no Maven: it is the phone/no-Gradle
# path. Termux-native aapt2, d8, zipalign and apksigner are preferred over the
# SDK's build-tools binaries, because the SDK ships glibc builds that bionic
# cannot execute. On a Linux host the SDK fallback is used instead.
#
# License: GPL-3.0-or-later. See LICENSE.

APKBUILD_VERSION=0.1.0

# Resolved by apkbuild_init; empty until then.
APKBUILD_SDK=""
APKBUILD_API=""
APKBUILD_ANDROID_JAR=""
APKBUILD_BUILD_TOOLS=""
APKBUILD_AAPT2=""
APKBUILD_D8=""
APKBUILD_ZIPALIGN=""
APKBUILD_APKSIGNER=""

apkbuild_die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

apkbuild_note() {
    printf '== %s\n' "$*" >&2
}

apkbuild_usage() {
    cat <<'USAGE'
apkbuild -- a Gradle-free Android APK/AAR build for Termux and Linux.

Usage:
  apkbuild doctor
  apkbuild sdk
  apkbuild compile --sources DIR [--sources DIR]... [--classpath PATH]...
                   [--out DIR] [--release N]
  apkbuild link    --manifest FILE [--res DIR] [--assets DIR] [--java DIR]
                   [--min-sdk N] [--target-sdk N] [--version-code N]
                   [--version-name S] --out FILE
  apkbuild dex     --in PATH [--classpath PATH]... [--min-sdk N] --out DIR
  apkbuild package --base FILE --dex DIR --out FILE [--lib DIR]
  apkbuild sign    --in FILE --out FILE [--keystore FILE]
                   [--store-password S] [--key-alias S] [--key-password S]
  apkbuild apk     --manifest FILE --sources DIR [--sources DIR]... --out FILE
                   [--res DIR] [--assets DIR] [--jni DIR] [--classpath PATH]...
                   [--min-sdk N] [--target-sdk N] [--version-code N]
                   [--version-name S] [--release N] [--abi ABI]...
  apkbuild aar     --manifest FILE --sources DIR [--sources DIR]... --out DIR
                   --group G --artifact A --version V
                   [--res DIR] [--classpath PATH]... [--release N]
                   [--min-sdk N] [--pom] [--javadoc] [--description S]
                   [--url S] [--license-name S] [--license-url S]
                   [--dependency G:A:V]...

Environment:
  ANDROID_HOME / ANDROID_SDK_ROOT   SDK root (otherwise ~/android-sdk)
  ANDROID_API                       platform to compile against (default: newest)
  BUILD_TOOLS                       build-tools version (default: newest)
  ANDROID_JAR                       explicit android.jar
  AAPT2, D8, ZIPALIGN, APKSIGNER    explicit tool paths
  JAVA_RELEASE                      javac --release level (default: 17)
  KEYSTORE, KEYSTORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD
                                    signing identity; a debug key is created
                                    under ~/.android when KEYSTORE is unset
USAGE
}

# --- discovery ----------------------------------------------------------------

# Prints the numeric part of android-<n> paths, sorted numerically.
apkbuild_newest_platform() {
    local best="" best_num=-1 dir num
    for dir in "$APKBUILD_SDK"/platforms/android-*; do
        [ -f "$dir/android.jar" ] || continue
        num=${dir##*/android-}
        case $num in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$num" -gt "$best_num" ]; then
            best_num=$num
            best=$num
        fi
    done
    [ -n "$best" ] || return 1
    printf '%s\n' "$best"
}

apkbuild_newest_build_tools() {
    local best="" best_key="" dir version
    for dir in "$APKBUILD_SDK"/build-tools/*; do
        [ -d "$dir" ] || continue
        version=${dir##*/}
        # sort -V handles 8.7.3 vs 35.0.0 without guessing at the digits.
        if [ -z "$best_key" ] || [ "$(printf '%s\n%s\n' "$best_key" "$version" | sort -V | tail -1)" = "$version" ]; then
            best_key=$version
            best=$dir
        fi
    done
    [ -n "$best" ] || return 1
    printf '%s\n' "$best"
}

# Finds the SDK and the platform, then the build-tools directory (if any).
# Never fails when a caller supplied ANDROID_JAR explicitly: a plain AAR build
# then needs no SDK at all.
apkbuild_init() {
    local candidate
    if [ -z "${APKBUILD_SDK:-}" ]; then
        for candidate in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "${HOME:-}/android-sdk" /usr/lib/android-sdk; do
            if [ -n "$candidate" ] && [ -d "$candidate/platforms" ]; then
                APKBUILD_SDK=$candidate
                break
            fi
        done
    fi
    if [ -z "${APKBUILD_ANDROID_JAR:-}" ]; then
        [ -n "$APKBUILD_SDK" ] || apkbuild_die "no Android SDK found. Set ANDROID_HOME, or install platforms under \$HOME/android-sdk."
        APKBUILD_API=${ANDROID_API:-}
        if [ -z "$APKBUILD_API" ]; then
            APKBUILD_API=$(apkbuild_newest_platform) || apkbuild_die "no platform with android.jar under $APKBUILD_SDK/platforms"
        fi
        APKBUILD_ANDROID_JAR=$APKBUILD_SDK/platforms/android-"$APKBUILD_API"/android.jar
        [ -f "$APKBUILD_ANDROID_JAR" ] || apkbuild_die "no $APKBUILD_ANDROID_JAR; install platforms;android-$APKBUILD_API"
    elif [ -z "${APKBUILD_API:-}" ]; then
        # android.jar was given without a platform number; the directory name is
        # the only source for targetSdk, so keep it when it is there.
        APKBUILD_API=$(basename "$(dirname "$APKBUILD_ANDROID_JAR")" | sed -n 's/^android-//p')
        APKBUILD_API=${APKBUILD_API:-35}
    fi

    if [ -z "${APKBUILD_BUILD_TOOLS:-}" ] && [ -n "$APKBUILD_SDK" ] && [ -d "$APKBUILD_SDK/build-tools" ]; then
        if [ -n "${BUILD_TOOLS:-}" ]; then
            APKBUILD_BUILD_TOOLS=$APKBUILD_SDK/build-tools/$BUILD_TOOLS
        else
            APKBUILD_BUILD_TOOLS=$(apkbuild_newest_build_tools || true)
        fi
    fi
    # An explicit android.jar has no platform directory to read the level from.
    APKBUILD_API=${APKBUILD_API:-35}
}

# Prefer an explicit path, then Termux's native tool on PATH, then build-tools.
apkbuild_resolve_tool() {
    local explicit=$1 name=$2 fallback=$3
    if [ -n "$explicit" ]; then
        [ -x "$explicit" ] || apkbuild_die "$name: '$explicit' is not executable"
        printf '%s\n' "$explicit"
        return 0
    fi
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    if [ -n "$fallback" ] && [ -x "$fallback" ]; then
        printf '%s\n' "$fallback"
        return 0
    fi
    return 1
}

apkbuild_tools() {
    apkbuild_init
    APKBUILD_AAPT2=$(apkbuild_resolve_tool "${AAPT2:-}" aapt2 "${APKBUILD_BUILD_TOOLS:-}/aapt2") \
        || apkbuild_die "missing aapt2: install Termux's aapt package, or set AAPT2 to a runnable aapt2"
    APKBUILD_D8=$(apkbuild_resolve_tool "${D8:-}" d8 "${APKBUILD_BUILD_TOOLS:-}/d8") \
        || apkbuild_die "missing d8: install the Termux d8 package, or set D8"
    APKBUILD_ZIPALIGN=$(apkbuild_resolve_tool "${ZIPALIGN:-}" zipalign "${APKBUILD_BUILD_TOOLS:-}/zipalign") \
        || apkbuild_die "missing zipalign: install the Termux zipalign package, or set ZIPALIGN"
    APKBUILD_APKSIGNER=$(apkbuild_resolve_tool "${APKSIGNER:-}" apksigner "${APKBUILD_BUILD_TOOLS:-}/apksigner") \
        || apkbuild_die "missing apksigner: install the Termux apksigner package, or set APKSIGNER"
    command -v javac >/dev/null 2>&1 || apkbuild_die "missing javac: install a JDK (pkg install openjdk-21)"
    command -v keytool >/dev/null 2>&1 || apkbuild_die "missing keytool: install a JDK"
    command -v python3 >/dev/null 2>&1 || apkbuild_die "missing python3: apkbuild uses it for the zip steps"
}

# --- helpers ------------------------------------------------------------------

# Reads android:minSdkVersion from a manifest so a build cannot prefer the
# tool's default over the value the same manifest hands to aapt2.
apkbuild_manifest_min_sdk() {
    sed -n 's/.*android:minSdkVersion="\([0-9][0-9]*\)".*/\1/p' "$1" | head -1
}

apkbuild_collect_sources() {
    local dir src found=0
    for dir in "$@"; do
        [ -d "$dir" ] || apkbuild_die "source directory does not exist: $dir"
        while IFS= read -r src; do
            printf '%s\n' "$src"
            found=1
        done < <(find "$dir" -name '*.java' -type f | sort)
    done
    [ "$found" = 1 ] || apkbuild_die "no .java files under: $*"
}

# Joins existing, colon-separated classpath entries. An empty result is allowed.
apkbuild_join_path() {
    local out="" part
    for part in "$@"; do
        [ -n "$part" ] || continue
        if [ -z "$out" ]; then out=$part; else out=$out:$part; fi
    done
    printf '%s\n' "$out"
}

apkbuild_jar_from() {
    local dir=$1 jar=$2
    python3 - "$dir" "$jar" <<'PY'
import os, sys, zipfile
root, jar = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(jar, 'w', zipfile.ZIP_DEFLATED) as z:
    for base, _, files in os.walk(root):
        for name in sorted(files):
            path = os.path.join(base, name)
            z.write(path, os.path.relpath(path, root))
PY
}

apkbuild_pack_apk() {
    local base=$1 dexdir=$2 libroot=$3 out=$4
    python3 - "$base" "$dexdir" "$libroot" "$out" <<'PY'
import os, sys, zipfile
base, dexdir, libroot, out = sys.argv[1:5]
with zipfile.ZipFile(base) as src, zipfile.ZipFile(out, 'w') as dst:
    for item in src.infolist():
        dst.writestr(item, src.read(item.filename))
    # d8 splits into classes.dex, classes2.dex, ... when one dex is not enough.
    for name in sorted(os.listdir(dexdir)):
        if name.endswith('.dex'):
            dst.write(os.path.join(dexdir, name), name)
    if libroot and os.path.isdir(libroot):
        for base_dir, _, files in os.walk(libroot):
            for name in sorted(files):
                path = os.path.join(base_dir, name)
                # lib/<abi>/<name>.so is what the loader looks for.
                dst.write(path, 'lib/' + os.path.relpath(path, libroot))
PY
}

apkbuild_pack_aar() {
    local jar=$1 manifest=$2 symbol_file=$3 resdir=$4 out=$5
    python3 - "$jar" "$manifest" "$symbol_file" "$resdir" "$out" <<'PY'
import os, sys, zipfile
jar, manifest, symbols, resdir, out = sys.argv[1:6]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    z.write(manifest, 'AndroidManifest.xml')
    z.write(jar, 'classes.jar')
    z.write(symbols, 'R.txt')
    if resdir and os.path.isdir(resdir):
        parent = os.path.dirname(os.path.abspath(resdir))
        for base, _, files in os.walk(resdir):
            for name in sorted(files):
                path = os.path.join(base, name)
                z.write(path, os.path.relpath(path, parent))
PY
}

apkbuild_sources_jar() {
    local jar=$1
    shift
    python3 - "$jar" "$@" <<'PY'
import os, sys, zipfile
jar, roots = sys.argv[1], sys.argv[2:]
with zipfile.ZipFile(jar, 'w', zipfile.ZIP_DEFLATED) as z:
    seen = set()
    for root in roots:
        for base, _, files in os.walk(root):
            for name in sorted(files):
                path = os.path.join(base, name)
                arc = os.path.relpath(path, root)
                if arc in seen:
                    continue
                seen.add(arc)
                z.write(path, arc)
PY
}

apkbuild_javadoc_jar() {
    local jar=$1 classpath=$2 title=$3
    shift 3
    local docs out
    command -v javadoc >/dev/null 2>&1 || apkbuild_die "javadoc not found; install the JDK's javadoc package or drop --javadoc"
    docs=$(mktemp -d "${TMPDIR:-/tmp}/apkbuild-javadoc.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$docs'" RETURN
    mapfile -t files < <(apkbuild_collect_sources "$@")
    javadoc -quiet -Xdoclint:none --release "${JAVA_RELEASE:-17}" \
        -classpath "$classpath" -windowtitle "$title" -doctitle "$title" \
        -d "$docs" "${files[@]}" >&2
    apkbuild_jar_from "$docs" "$jar"
}

apkbuild_write_pom() {
    local file=$1 group=$2 artifact=$3 version=$4 description=$5 url=$6
    local license_name=$7 license_url=$8
    shift 8
    local dependencies=${1:-}
    cat > "$file" <<POM
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <groupId>$group</groupId>
    <artifactId>$artifact</artifactId>
    <version>$version</version>
    <packaging>aar</packaging>
    <name>$artifact</name>
    <description>$description</description>
    <url>$url</url>
    <licenses>
        <license>
            <name>$license_name</name>
            <url>$license_url</url>
        </license>
    </licenses>
    <developers>
        <developer>
            <id>MBanucu</id>
            <name>MBanucu</name>
            <url>https://github.com/MBanucu</url>
        </developer>
    </developers>
    <scm>
        <connection>scm:git:$url.git</connection>
        <developerConnection>scm:git:git@github.com:MBanucu/$artifact.git</developerConnection>
        <url>$url</url>
    </scm>
    <dependencies>
$dependencies
    </dependencies>
</project>
POM
}

# Prints a <dependency> block for one --dependency group:artifact:version.
apkbuild_dependency_block() {
    local spec=$1 group artifact version
    IFS=: read -r group artifact version <<< "$spec"
    [ -n "$group" ] && [ -n "$artifact" ] && [ -n "$version" ] \
        || apkbuild_die "--dependency wants group:artifact:version, got '$spec'"
    cat <<DEP
        <dependency>
            <groupId>$group</groupId>
            <artifactId>$artifact</artifactId>
            <version>$version</version>
            <scope>compile</scope>
        </dependency>
DEP
}

# --- internal build steps -----------------------------------------------------

apkbuild_do_compile() {
    local out=$1 release=$2 classpath=$3
    shift 3
    local -a sources=()
    mapfile -t sources < <(apkbuild_collect_sources "$@")
    mkdir -p "$out"
    apkbuild_note "javac -> $out"
    javac -nowarn --release "$release" -classpath "$classpath" -d "$out" "${sources[@]}"
}

apkbuild_do_link() {
    local manifest=$1 resdir=$2 assets=$3 javadir=$4 min_sdk=$5 target_sdk=$6
    local version_code=$7 version_name=$8 out=$9
    local work=${10}
    local -a flat=() link_res=()

    [ -f "$manifest" ] || apkbuild_die "no manifest at $manifest"
    if [ -n "$resdir" ]; then
        [ -d "$resdir" ] || apkbuild_die "no res directory at $resdir"
        mkdir -p "$work/res"
        apkbuild_note "aapt2 compile $resdir"
        "$APKBUILD_AAPT2" compile --dir "$resdir" -o "$work/res"
        while IFS= read -r flat_file; do link_res+=("$flat_file"); done \
            < <(find "$work/res" -name '*.flat' | sort)
    fi
    mkdir -p "$javadir"
    local -a asset_args=()
    [ -n "$assets" ] && asset_args=(--assets "$assets")
    apkbuild_note "aapt2 link -> $out"
    "$APKBUILD_AAPT2" link -o "$out" \
        -I "$APKBUILD_ANDROID_JAR" \
        --manifest "$manifest" \
        --java "$javadir" \
        --min-sdk-version "$min_sdk" \
        --target-sdk-version "$target_sdk" \
        --version-code "$version_code" \
        --version-name "$version_name" \
        "${asset_args[@]}" \
        ${link_res[@]+"${link_res[@]}"}
}

apkbuild_do_dex() {
    local input=$1 out=$2 min_sdk=$3 classpath=$4
    shift 4
    local -a extra=()
    if [ -n "$classpath" ]; then
        extra=(--classpath "$classpath")
    fi
    mkdir -p "$out"
    # d8 accepts jars and .class files, not a directory. `compile` writes a
    # directory, so jar it here rather than making every caller repeat this.
    local jar=""
    if [ -d "$input" ]; then
        jar=$(mktemp "${TMPDIR:-/tmp}/apkbuild-classes.XXXXXX.jar")
        apkbuild_jar_from "$input" "$jar"
        input=$jar
    fi
    apkbuild_note "d8 $input -> $out"
    "$APKBUILD_D8" --lib "$APKBUILD_ANDROID_JAR" --min-api "$min_sdk" \
        ${extra[@]+"${extra[@]}"} --output "$out" "$input" "$@"
    [ -z "$jar" ] || rm -f "$jar"
}

apkbuild_do_sign() {
    local input=$1 out=$2 keystore=$3 storepass=$4 alias=$5 keypass=$6
    local aligned
    aligned=$(dirname "$out")/.apkbuild-aligned.apk
    "$APKBUILD_ZIPALIGN" -f 4 "$input" "$aligned"
    if [ -z "$keystore" ]; then
        keystore=${HOME:-.}/.android/debug.keystore
        if [ ! -f "$keystore" ]; then
            apkbuild_note "creating debug keystore $keystore" >&2
            mkdir -p "$(dirname "$keystore")"
            keytool -genkeypair -keystore "$keystore" -storepass android \
                -keypass android -alias androiddebugkey -keyalg RSA -keysize 2048 \
                -validity 10000 -dname 'CN=Android Debug,O=Android,C=US' >/dev/null
        fi
    fi
    [ -f "$keystore" ] || apkbuild_die "no keystore at $keystore"
    apkbuild_note "apksigner -> $out"
    "$APKBUILD_APKSIGNER" sign --ks "$keystore" --ks-pass "pass:$storepass" \
        --key-pass "pass:$keypass" --ks-key-alias "$alias" --out "$out" "$aligned"
    rm -f "$aligned"
}

# --- commands -----------------------------------------------------------------

apkbuild_cmd_doctor() {
    apkbuild_tools
    printf 'apkbuild      %s\n' "$APKBUILD_VERSION"
    printf 'sdk           %s\n' "${APKBUILD_SDK:-<none: ANDROID_JAR supplied>}"
    printf 'platform      android-%s\n' "$APKBUILD_API"
    printf 'android.jar   %s\n' "$APKBUILD_ANDROID_JAR"
    printf 'build-tools   %s\n' "${APKBUILD_BUILD_TOOLS:-<none>}"
    printf 'aapt2         %s\n' "$APKBUILD_AAPT2"
    printf 'd8            %s\n' "$APKBUILD_D8"
    printf 'zipalign      %s\n' "$APKBUILD_ZIPALIGN"
    printf 'apksigner     %s\n' "$APKBUILD_APKSIGNER"
    printf 'javac         %s\n' "$(command -v javac)"
    printf 'java release  %s\n' "${JAVA_RELEASE:-17}"
}

apkbuild_cmd_sdk() {
    apkbuild_init
    printf 'ANDROID_HOME=%s\n' "${APKBUILD_SDK:-}"
    printf 'ANDROID_JAR=%s\n' "$APKBUILD_ANDROID_JAR"
    printf 'ANDROID_API=%s\n' "$APKBUILD_API"
    printf 'BUILD_TOOLS=%s\n' "${APKBUILD_BUILD_TOOLS:-}"
}

apkbuild_cmd_compile() {
    local out="" release=${JAVA_RELEASE:-17}
    local -a sources=() classpath=()
    while [ $# -gt 0 ]; do
        case $1 in
            --sources) sources+=("${2:?}"); shift 2 ;;
            --classpath) classpath+=("${2:?}"); shift 2 ;;
            --out) out=${2:?}; shift 2 ;;
            --release) release=${2:?}; shift 2 ;;
            -h|--help) apkbuild_usage; exit 0 ;;
            *) apkbuild_die "compile: unknown option $1" ;;
        esac
    done
    [ -n "$out" ] || apkbuild_die "compile: --out is required"
    [ ${#sources[@]} -gt 0 ] || apkbuild_die "compile: --sources is required"
    apkbuild_init
    apkbuild_do_compile "$out" "$release" "$(apkbuild_join_path "$APKBUILD_ANDROID_JAR" ${classpath[@]+"${classpath[@]}"})" \
        "${sources[@]}"
}

apkbuild_cmd_link() {
    local manifest="" resdir="" assets="" javadir="" min_sdk="" target_sdk=""
    local version_code=1 version_name="1.0" out=""
    while [ $# -gt 0 ]; do
        case $1 in
            --manifest) manifest=${2:?}; shift 2 ;;
            --res) resdir=${2:?}; shift 2 ;;
            --assets) assets=${2:?}; shift 2 ;;
            --java) javadir=${2:?}; shift 2 ;;
            --min-sdk) min_sdk=${2:?}; shift 2 ;;
            --target-sdk) target_sdk=${2:?}; shift 2 ;;
            --version-code) version_code=${2:?}; shift 2 ;;
            --version-name) version_name=${2:?}; shift 2 ;;
            --out) out=${2:?}; shift 2 ;;
            -h|--help) apkbuild_usage; exit 0 ;;
            *) apkbuild_die "link: unknown option $1" ;;
        esac
    done
    [ -n "$manifest" ] || apkbuild_die "link: --manifest is required"
    [ -n "$out" ] || apkbuild_die "link: --out is required"
    apkbuild_tools
    min_sdk=${min_sdk:-$(apkbuild_manifest_min_sdk "$manifest")}
    min_sdk=${min_sdk:-24}
    target_sdk=${target_sdk:-$APKBUILD_API}
    javadir=${javadir:-$(dirname "$out")/gen}
    local work
    work=$(mktemp -d "${TMPDIR:-/tmp}/apkbuild-link.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT
    apkbuild_do_link "$manifest" "$resdir" "$assets" "$javadir" "$min_sdk" \
        "$target_sdk" "$version_code" "$version_name" "$out" "$work"
}

apkbuild_cmd_dex() {
    local input="" out="" min_sdk=""
    local -a classpath=()
    while [ $# -gt 0 ]; do
        case $1 in
            --in) input=${2:?}; shift 2 ;;
            --out) out=${2:?}; shift 2 ;;
            --min-sdk) min_sdk=${2:?}; shift 2 ;;
            --classpath) classpath+=("${2:?}"); shift 2 ;;
            -h|--help) apkbuild_usage; exit 0 ;;
            *) apkbuild_die "dex: unknown option $1" ;;
        esac
    done
    [ -n "$input" ] || apkbuild_die "dex: --in is required"
    [ -n "$out" ] || apkbuild_die "dex: --out is required"
    [ -e "$input" ] || apkbuild_die "dex: no $input"
    apkbuild_tools
    min_sdk=${min_sdk:-24}
    apkbuild_do_dex "$input" "$out" "$min_sdk" "$(apkbuild_join_path ${classpath[@]+"${classpath[@]}"})"
}

apkbuild_cmd_package() {
    local base="" dexdir="" libroot="" out=""
    while [ $# -gt 0 ]; do
        case $1 in
            --base) base=${2:?}; shift 2 ;;
            --dex) dexdir=${2:?}; shift 2 ;;
            --lib) libroot=${2:?}; shift 2 ;;
            --out) out=${2:?}; shift 2 ;;
            -h|--help) apkbuild_usage; exit 0 ;;
            *) apkbuild_die "package: unknown option $1" ;;
        esac
    done
    [ -f "$base" ] || apkbuild_die "package: no base APK at $base"
    [ -d "$dexdir" ] || apkbuild_die "package: no dex directory at $dexdir"
    [ -n "$out" ] || apkbuild_die "package: --out is required"
    command -v python3 >/dev/null 2>&1 || apkbuild_die "missing python3"
    apkbuild_pack_apk "$base" "$dexdir" "$libroot" "$out"
    apkbuild_note "packaged $out"
}

apkbuild_cmd_sign() {
    local input="" out="" keystore="" storepass="" alias="" keypass=""
    while [ $# -gt 0 ]; do
        case $1 in
            --in) input=${2:?}; shift 2 ;;
            --out) out=${2:?}; shift 2 ;;
            --keystore) keystore=${2:?}; shift 2 ;;
            --store-password) storepass=${2:?}; shift 2 ;;
            --key-alias) alias=${2:?}; shift 2 ;;
            --key-password) keypass=${2:?}; shift 2 ;;
            -h|--help) apkbuild_usage; exit 0 ;;
            *) apkbuild_die "sign: unknown option $1" ;;
        esac
    done
    [ -f "$input" ] || apkbuild_die "sign: no APK at $input"
    [ -n "$out" ] || apkbuild_die "sign: --out is required"
    apkbuild_tools
    keystore=${keystore:-${KEYSTORE:-}}
    storepass=${storepass:-${KEYSTORE_PASSWORD:-android}}
    alias=${alias:-${KEY_ALIAS:-androiddebugkey}}
    keypass=${keypass:-${KEY_PASSWORD:-$storepass}}
    apkbuild_do_sign "$input" "$out" "$keystore" "$storepass" "$alias" "$keypass"
    apkbuild_note "signed $out"
}

apkbuild_cmd_apk() {
    local manifest="" resdir="" assets="" jnidir="" out=""
    local min_sdk="" target_sdk="" version_code=1 version_name="1.0"
    local release=${JAVA_RELEASE:-17} abi=arm64-v8a
    local -a sources=() classpath=() abis=()
    while [ $# -gt 0 ]; do
        case $1 in
            --manifest) manifest=${2:?}; shift 2 ;;
            --sources) sources+=("${2:?}"); shift 2 ;;
            --classpath) classpath+=("${2:?}"); shift 2 ;;
            --res) resdir=${2:?}; shift 2 ;;
            --assets) assets=${2:?}; shift 2 ;;
            --jni) jnidir=${2:?}; shift 2 ;;
            --abi) abi=${2:?}; shift 2 ;;
            --out) out=${2:?}; shift 2 ;;
            --min-sdk) min_sdk=${2:?}; shift 2 ;;
            --target-sdk) target_sdk=${2:?}; shift 2 ;;
            --version-code) version_code=${2:?}; shift 2 ;;
            --version-name) version_name=${2:?}; shift 2 ;;
            --release) release=${2:?}; shift 2 ;;
            -h|--help) apkbuild_usage; exit 0 ;;
            *) apkbuild_die "apk: unknown option $1" ;;
        esac
    done
    [ -n "$manifest" ] || apkbuild_die "apk: --manifest is required"
    [ ${#sources[@]} -gt 0 ] || apkbuild_die "apk: --sources is required"
    [ -n "$out" ] || apkbuild_die "apk: --out is required"
    apkbuild_tools
    min_sdk=${min_sdk:-$(apkbuild_manifest_min_sdk "$manifest")}
    min_sdk=${min_sdk:-24}
    target_sdk=${target_sdk:-$APKBUILD_API}

    local work
    work=$(mktemp -d "${TMPDIR:-/tmp}/apkbuild-apk.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT
    mkdir -p "$work/classes" "$work/dex" "$work/gen" "$work/lib"

    apkbuild_do_link "$manifest" "$resdir" "$assets" "$work/gen" "$min_sdk" \
        "$target_sdk" "$version_code" "$version_name" "$work/base.apk" "$work/link"

    local classpath_path
    classpath_path=$(apkbuild_join_path "$APKBUILD_ANDROID_JAR" ${classpath[@]+"${classpath[@]}"})
    local -a compile_sources=("${sources[@]}")
    [ -d "$work/gen" ] && compile_sources+=("$work/gen")
    apkbuild_do_compile "$work/classes" "$release" "$classpath_path" "${compile_sources[@]}"
    apkbuild_jar_from "$work/classes" "$work/classes.jar"
    apkbuild_do_dex "$work/classes.jar" "$work/dex" "$min_sdk" \
        "$(apkbuild_join_path ${classpath[@]+"${classpath[@]}"})"

    if [ -n "$jnidir" ]; then
        [ -d "$jnidir" ] || apkbuild_die "apk: no JNI directory at $jnidir"
        command -v clang >/dev/null 2>&1 || apkbuild_die "apk: --jni needs clang"
        local libname
        libname=$(basename "$jnidir" | tr '-' '_')
        mkdir -p "$work/lib/$abi"
        apkbuild_note "clang $abi -> lib$libname.so"
        clang --target="${abi}-linux-android$min_sdk" -fPIC -shared -O2 \
            -I "${PREFIX:-/usr}/include" \
            -o "$work/lib/$abi/lib$libname.so" "$jnidir"/*.c
        command -v patchelf >/dev/null 2>&1 && patchelf --remove-rpath "$work/lib/$abi/lib$libname.so" || true
    fi

    apkbuild_pack_apk "$work/base.apk" "$work/dex" "$work/lib" "$work/unaligned.apk"
    local keystore storepass alias keypass
    keystore=${KEYSTORE:-}
    storepass=${KEYSTORE_PASSWORD:-android}
    alias=${KEY_ALIAS:-androiddebugkey}
    keypass=${KEY_PASSWORD:-$storepass}
    mkdir -p "$(dirname "$out")"
    apkbuild_do_sign "$work/unaligned.apk" "$out" "$keystore" "$storepass" "$alias" "$keypass"
    apkbuild_note "built $out ($(wc -c < "$out") bytes)"
}

apkbuild_cmd_aar() {
    local manifest="" resdir="" outdir="" group="" artifact="" version=""
    local release=${JAVA_RELEASE:-17} min_sdk="" make_pom=0 make_javadoc=0
    local description="" url="https://github.com/MBanucu"
    local license_name="GNU General Public License v3.0 or later"
    local license_url="https://www.gnu.org/licenses/gpl-3.0-standalone.html"
    local -a sources=() classpath=() dependencies=()
    while [ $# -gt 0 ]; do
        case $1 in
            --manifest) manifest=${2:?}; shift 2 ;;
            --sources) sources+=("${2:?}"); shift 2 ;;
            --classpath) classpath+=("${2:?}"); shift 2 ;;
            --res) resdir=${2:?}; shift 2 ;;
            --out) outdir=${2:?}; shift 2 ;;
            --group) group=${2:?}; shift 2 ;;
            --artifact) artifact=${2:?}; shift 2 ;;
            --version) version=${2:?}; shift 2 ;;
            --release) release=${2:?}; shift 2 ;;
            --min-sdk) min_sdk=${2:?}; shift 2 ;;
            --pom) make_pom=1; shift ;;
            --javadoc) make_javadoc=1; shift ;;
            --description) description=${2:?}; shift 2 ;;
            --url) url=${2:?}; shift 2 ;;
            --license-name) license_name=${2:?}; shift 2 ;;
            --license-url) license_url=${2:?}; shift 2 ;;
            --dependency) dependencies+=("${2:?}"); shift 2 ;;
            -h|--help) apkbuild_usage; exit 0 ;;
            *) apkbuild_die "aar: unknown option $1" ;;
        esac
    done
    [ -f "$manifest" ] || apkbuild_die "aar: --manifest is required"
    [ ${#sources[@]} -gt 0 ] || apkbuild_die "aar: --sources is required"
    [ -n "$outdir" ] || apkbuild_die "aar: --out is required"
    [ -n "$group" ] && [ -n "$artifact" ] && [ -n "$version" ] \
        || apkbuild_die "aar: --group, --artifact and --version are required for the coordinates"
    apkbuild_tools
    min_sdk=${min_sdk:-$(apkbuild_manifest_min_sdk "$manifest")}
    min_sdk=${min_sdk:-24}

    local work
    work=$(mktemp -d "${TMPDIR:-/tmp}/apkbuild-aar.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT
    mkdir -p "$outdir" "$work/classes" "$work/gen"

    if [ -n "$resdir" ]; then
        [ -d "$resdir" ] || apkbuild_die "aar: no res directory at $resdir"
        mkdir -p "$work/res"
        apkbuild_note "aapt2 compile $resdir"
        "$APKBUILD_AAPT2" compile --dir "$resdir" -o "$work/res"
        local -a flat=()
        while IFS= read -r flat_file; do flat+=("$flat_file"); done \
            < <(find "$work/res" -name '*.flat' | sort)
        apkbuild_note "aapt2 link --static-lib"
        "$APKBUILD_AAPT2" link --static-lib -o "$work/static.apk" \
            -I "$APKBUILD_ANDROID_JAR" --manifest "$manifest" \
            --java "$work/gen" --output-text-symbols "$work/R.txt" \
            "${flat[@]}"
    else
        : > "$work/R.txt"
    fi

    local classpath_path
    classpath_path=$(apkbuild_join_path "$APKBUILD_ANDROID_JAR" ${classpath[@]+"${classpath[@]}"})
    local -a compile_sources=("${sources[@]}")
    [ -d "$work/gen" ] && compile_sources+=("$work/gen")
    apkbuild_do_compile "$work/classes" "$release" "$classpath_path" "${compile_sources[@]}"
    apkbuild_jar_from "$work/classes" "$outdir/$artifact-$version.jar"
    apkbuild_do_dex "$outdir/$artifact-$version.jar" "$work/dex" "$min_sdk" \
        "$(apkbuild_join_path ${classpath[@]+"${classpath[@]}"})"

    apkbuild_pack_aar "$outdir/$artifact-$version.jar" "$manifest" "$work/R.txt" "$resdir" \
        "$outdir/$artifact-$version.aar"
    apkbuild_sources_jar "$outdir/$artifact-$version-sources.jar" "${sources[@]}"
    if [ "$make_javadoc" = 1 ]; then
        apkbuild_javadoc_jar "$outdir/$artifact-$version-javadoc.jar" "$classpath_path" \
            "$artifact $version" "${sources[@]}"
    fi
    if [ "$make_pom" = 1 ]; then
        local blocks=""
        if [ ${#dependencies[@]} -gt 0 ]; then
            blocks=$(for dep in "${dependencies[@]}"; do apkbuild_dependency_block "$dep"; done)
        fi
        apkbuild_write_pom "$outdir/$artifact-$version.pom" "$group" "$artifact" "$version" \
            "${description:-$artifact}" "$url" "$license_name" "$license_url" "$blocks"
    fi
    local built
    for built in "$outdir/$artifact-$version.aar" "$outdir/$artifact-$version.jar" \
            "$outdir/$artifact-$version-sources.jar"; do
        apkbuild_note "built $built ($(wc -c < "$built") bytes)"
    done
}
