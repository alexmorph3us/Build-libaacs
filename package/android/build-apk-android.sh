#!/bin/sh
#
# Package prebuilt libaacs shared objects into an installable APK, one
# entry per ABI. See README.md for how the libraries are built and what
# the # variables below mean.
#
# Usage:
#   ./build-apk-android.sh
#
# with LIBAACS and ANDROID_SDK in the environment.

set -eu

SRC_DIR=$(cd "$(dirname "$0")" && pwd)

# ANDROID_HOME is what the SDK's own tooling sets, so take it as a fallback.
ANDROID_SDK=${ANDROID_SDK:-${ANDROID_HOME:-}}
: "${ANDROID_SDK:?set ANDROID_SDK (or ANDROID_HOME) to the Android SDK root}"

# The four build directories, $LIBAACS/build-<abi>, as left by the recipe
# in README.md. Nothing is installed and nothing is staged by hand.
: "${LIBAACS:?set LIBAACS to the libaacs tree the ABIs were built in}"

OUT=${OUT:=$SRC_DIR/out}
MANIFEST=${MANIFEST:=$SRC_DIR/AndroidManifest.xml}

MIN_SDK=${MIN_SDK:=23}
TARGET_SDK=${TARGET_SDK:=35}
VERSION_CODE=${VERSION_CODE:=1}
VERSION_NAME=${VERSION_NAME:=0.11.1}

PAGE=16384

# The debug keystore is the default only because every SDK installation has
# one. A build meant for distribution passes its own, and always the same
# one: see README.md.
KEYSTORE=${KEYSTORE:=$HOME/.android/debug.keystore}
KEY_ALIAS=${KEY_ALIAS:=androiddebugkey}
KEYSTORE_PASS=${KEYSTORE_PASS:=android}
KEY_PASS=${KEY_PASS:=$KEYSTORE_PASS}

# Latest build-tools and latest platform, unless told otherwise.
BUILD_TOOLS=${BUILD_TOOLS:=$(ls "$ANDROID_SDK/build-tools" 2>/dev/null | sort -V | tail -1)}
[ -n "$BUILD_TOOLS" ] || { echo "no build-tools under $ANDROID_SDK" >&2; exit 1; }
BT=$ANDROID_SDK/build-tools/$BUILD_TOOLS

ANDROID_JAR=${ANDROID_JAR:=$(ls -d "$ANDROID_SDK"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)}
[ -n "$ANDROID_JAR" ] || { echo "no platform under $ANDROID_SDK/platforms" >&2; exit 1; }

for tool in aapt2 zipalign apksigner; do
    [ -x "$BT/$tool" ] || { echo "$tool not found in $BT" >&2; exit 1; }
done
"$BT/apksigner" sign --help 2>&1 | grep -q -- --alignment-preserved || {
    echo "apksigner in build-tools $BUILD_TOOLS has no --alignment-preserved," >&2
    echo "so it will realign the libraries to 4 bytes while signing." >&2
    echo "Install build-tools 35.0.0 or later, or set BUILD_TOOLS to one." >&2
    exit 1
}
command -v zip >/dev/null || { echo "zip not found" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "no manifest at $MANIFEST" >&2; exit 1; }
[ -f "$KEYSTORE" ] || {
    echo "no keystore at $KEYSTORE - create one with:" >&2
    echo "  keytool -genkeypair -keystore $KEYSTORE -alias $KEY_ALIAS \\" >&2
    echo "          -keyalg RSA -keysize 2048 -validity 10000" >&2
    exit 1
}

echo "build-tools $BUILD_TOOLS"
echo "platform    $ANDROID_JAR"

# ---------------------------------------------------------------------------
# Stage the libraries.
#
# One place per ABI: $LIBAACS/build-<abi>/.libs, where libtool leaves the
# library after a plain "make".
#
# The ABI directory names are the ones the linker will be given in the "!/"
# path, so they are the APK's own convention (arm64-v8a, armeabi-v7a, ...)
# and not the ones the package manager uses when it extracts (arm64, arm).
# Build directories named build-<abi> as in README.md line up with that, so
# this is a copy and not a translation.
# ---------------------------------------------------------------------------

# The regular file to package from directory $1, or nothing.
#
# Two layouts, because libtool names the output differently per platform:
# an Android host gets one unversioned libaacs.so, while a versioning host
# gets libaacs.so.<version> with libaacs.so.0 and libaacs.so as symlinks to
# it. Most specific first, and only regular files, so the symlinks of the
# second layout are stepped over - a zip entry cannot be a symlink.
#
# -L rather than following the link, because copying through the symlink
# would work here and then hide the day the directory holds two versioned
# files and the link points at the older one.
find_so() {
    for cand in "$1"/libaacs.so.0.* "$1"/libaacs.so.0 "$1"/libaacs.so; do
        if [ -f "$cand" ] && [ ! -L "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done
    return 1
}

# What .libs holds is the unstripped library, while install-strip's output
# is stripped, so strip on the way in and the APK comes out the same size
# from either source. Only if a strip is reachable: $STRIP is exported by
# the build recipe, and llvm-strip is on PATH in a shell that has just
# built an ABI. Otherwise the library is copied as it is, which costs size
# and nothing else.
STRIP_TOOL=
for s in "${STRIP:-}" llvm-strip; do
    if [ -n "$s" ] && command -v "$s" >/dev/null 2>&1; then
        STRIP_TOOL=$s
        break
    fi
done

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

ABIS=
for ABI in arm64-v8a armeabi-v7a x86_64 x86; do
    DIR=$LIBAACS/build-$ABI/.libs

    # An ABI that was not built for is skipped with a line saying so. One
    # whose .libs is there but holds nothing recognisable is an error:
    # silently dropping it produces an APK missing an architecture and says
    # so nowhere.
    if [ ! -d "$DIR" ]; then
        printf '%-12s%s\n' "$ABI" "not built, skipped"
        continue
    fi
    SO=$(find_so "$DIR") || {
        echo "!! $ABI: no libaacs.so* in $DIR" >&2
        exit 1
    }

    # Renamed on the way in: the entry has to be called libaacs.so.0, the
    # name the consumer puts in the "!/" path. It is deliberately not the
    # library's SONAME - libtool leaves that libaacs.so on Android - and it
    # must keep the ".so.0" ending, or the package manager would treat it
    # as a native library and extract it. See README.md.
    mkdir -p "$STAGE/lib/$ABI"
    if [ -n "$STRIP_TOOL" ]; then
        "$STRIP_TOOL" --strip-unneeded "$SO" -o "$STAGE/lib/$ABI/libaacs.so.0"
    else
        cp "$SO" "$STAGE/lib/$ABI/libaacs.so.0"
    fi
    ABIS="$ABIS $ABI"
    printf '%-12s%s\n' "$ABI" "$SO"

    # An ELF whose LOAD segments are aligned to less than the runtime page
    # size cannot be mapped on a device with that page size, and no amount
    # of zip alignment fixes it: this is a link-time property of the .so,
    # settled by -Wl,-z,max-page-size, which configure.ac passes for
    # *android* hosts. Checked and not assumed, because it is the one flaw
    # that survives everything below - the APK builds, installs and looks
    # right, and the failure shows up as a dlopen() that refuses on the
    # devices nobody tests on first.
    #
    # Any readelf that knows the target will do, so the build machine's own
    # is the default; set READELF to the NDK's llvm-readelf if it does not.
    if command -v "${READELF:=readelf}" >/dev/null; then
        for align in $("$READELF" -lW "$SO" 2>/dev/null |
                       awk '$1 == "LOAD" { print $NF }'); do
            [ "$((align))" -ge "$PAGE" ] || {
                echo "!! $ABI: LOAD segment aligned to $align, not $PAGE -" \
                     "will not load on a 16 KB page device." \
                     "Rebuild with -Wl,-z,max-page-size=$PAGE in LDFLAGS." >&2
                exit 1
            }
        done
    fi
done

[ -n "$ABIS" ] || {
    echo "no libaacs in $LIBAACS/build-<abi>/.libs - see README.md" >&2
    exit 1
}
echo "ABIs       $ABIS"

# ---------------------------------------------------------------------------
# Package.
# ---------------------------------------------------------------------------
mkdir -p "$OUT"
UNSIGNED=$STAGE/unsigned.apk
ALIGNED=$STAGE/aligned.apk
APK=$OUT/libaacs-provider.apk

"$BT/aapt2" link \
    --manifest "$MANIFEST" \
    -I "$ANDROID_JAR" \
    --min-sdk-version "$MIN_SDK" \
    --target-sdk-version "$TARGET_SDK" \
    --version-code "$VERSION_CODE" \
    --version-name "$VERSION_NAME" \
    -o "$UNSIGNED"

# -0 stores, -X drops the extra fields zipalign would have to work around,
# -r because the tree is two deep. Relative paths, hence the subshell: the
# entry names are the paths as given, and they must be "lib/<abi>/..." with
# nothing in front.
#
# -D IS LOAD-BEARING, not tidiness. Without it -r also writes an entry per
# directory - "lib/", "lib/<abi>/" - and apksigner deletes those while
# signing, since a directory has no data to digest. Deleting them shifts
# every entry behind them by the size of their local file headers, and an
# entry whose output offset differs from its input offset is no longer
# covered by --alignment-preserved: apksigner then has to decide an
# alignment for it, looks for a 0xd935 alignment record in the extra field,
# finds none it can use, and falls back to the filename rule - the page
# size for names ending in ".so", four bytes for everything else, which is
# what ".so.0" counts as. The libraries land 80-odd bytes early and the
# check below catches it.
#
# With no directory entries there is nothing for apksigner to remove, every
# entry keeps its offset, and each one is copied verbatim.
( cd "$STAGE" && zip -q -0 -X -D -r "$UNSIGNED" lib )

"$BT/zipalign" -f "$PAGE" "$UNSIGNED" "$ALIGNED"

# CHECKED HERE AND AGAIN AFTER SIGNING, so that a failure names the step
# that caused it. The two tools fail the same way from the outside - the
# libraries end up misaligned - and they need different fixes.
"$BT/zipalign" -c -v "$PAGE" "$ALIGNED" || {
    echo "!! zipalign did not align the entries to $PAGE." >&2
    echo "   The per-entry report above says which ones and at what offset." >&2
    exit 1
}

"$BT/apksigner" sign \
    --ks "$KEYSTORE" \
    --ks-key-alias "$KEY_ALIAS" \
    --ks-pass "pass:$KEYSTORE_PASS" \
    --key-pass "pass:$KEY_PASS" \
    --min-sdk-version "$MIN_SDK" \
    --alignment-preserved \
    --out "$APK" \
    "$ALIGNED"

# ---------------------------------------------------------------------------
# Verify, because every failure this guards against is silent.
#
# The alignment is checked twice - once above, right after zipalign, and
# once here, after signing - because those are two different failures with
# two different fixes, and from the outside they look identical.
#
# Signing should be the innocent one. With --alignment-preserved,
# ApkSigner.outputInputJarEntryLfhRecord() copies an entry verbatim when
# its output offset equals its input offset, and the JAR signature entries
# are written only after every input entry has been copied - so nothing is
# inserted ahead of the libraries and their offsets cannot move. If this
# check fails while the one above passed, that reasoning is wrong and the
# per-entry report says where.
# ---------------------------------------------------------------------------
"$BT/zipalign" -c -v "$PAGE" "$APK" || {
    echo "!! the entries were ${PAGE}-aligned before signing and are not after," >&2
    echo "   so apksigner moved them despite --alignment-preserved." >&2
    exit 1
}
"$BT/apksigner" verify --min-sdk-version "$MIN_SDK" "$APK"

if command -v unzip >/dev/null; then
    if unzip -v "$APK" | grep 'libaacs\.so\.0' | grep -qv 'Stored'; then
        echo "!! some libaacs.so.0 entries are compressed" >&2
        exit 1
    fi
fi

echo
echo "=== $APK ==="
for ABI in $ABIS; do
    echo "  !/lib/$ABI/libaacs.so.0"
done
echo
echo "sha256 $(sha256sum "$APK" | cut -d' ' -f1)"
