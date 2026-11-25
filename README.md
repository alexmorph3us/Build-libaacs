# libaacs provider APK

An Android package whose only content is `libaacs.so.0`, one copy per ABI.
It installs no code, no activity and no service: an application that has
this package installed opens the library straight out of it, by handing the
dynamic linker a path into the APK.

    /data/app/~~.../org.libaacs.provider-.../base.apk!/lib/arm64-v8a/libaacs.so.0

The package name is `org.libaacs.provider`, declared in `AndroidManifest.xml`.


## Contents

    AndroidManifest.xml     the package: name, version, and nothing else
    build-apk-android.sh    packages prebuilt libraries into a signed APK
    README.md               this file

The manifest declares no component and no permission.


## Requirements

To build the libraries:

* the Android NDK
* the usual autotools chain — autoconf, automake, libtool, pkg-config —
  plus bison and flex
* a libgcrypt and a libgpg-error built for each ABI (see below)

To build the APK:

* the Android SDK: **build-tools 35 or later**
* `zip`
* a keystore


## Building the libraries

libaacs is configured and built once per ABI, out of tree. libgcrypt and
libgpg-error have to exist for the target already — the NDK sysroot has
neither, and Android ships neither — as static archives, so that they end
up absorbed into `libaacs.so.0` and nothing extra has to be packaged.

VLC's contribs are one place they exist for exactly these ABIs. Any prefix
holding a target build of the two works the same way; only the value of
`CONTRIB` below changes.

For **arm64-v8a**:

    export ANDROID_NDK=/path/to/android-ndk
    export LIBAACS=/path/to/libaacs
    VLC_SRC=/path/to/vlc                        # the tree whose contribs are built

    TOOLCHAIN=$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64   # darwin-x86_64 on macOS
    CONTRIB=$VLC_SRC/contrib/aarch64-linux-android

    cd "$LIBAACS"
    ./bootstrap                     # git checkout only
    rm -rf build-arm64-v8a && mkdir build-arm64-v8a && cd build-arm64-v8a

    export PATH=$TOOLCHAIN/bin:$PATH
    export CC=aarch64-linux-android21-clang
    export AR=llvm-ar RANLIB=llvm-ranlib NM=llvm-nm STRIP=llvm-strip
    export PKG_CONFIG_LIBDIR=$CONTRIB/lib/pkgconfig
    export PKG_CONFIG_PATH= PKG_CONFIG_SYSROOT_DIR=
    export PKG_CONFIG="pkg-config --static"

    ../configure --host=aarch64-linux-android --prefix=/ \
                 --disable-static --enable-shared \
                 --with-libgcrypt-prefix="$CONTRIB" \
                 CFLAGS="-O2 -fPIC" \
                 LDFLAGS="-L$CONTRIB/lib -Wl,--exclude-libs,ALL"

    make -j"$(nproc)"

and the same for the other ABIs, with three names changed:

| ABI | CC prefix | `--host` | contrib directory |
| --- | --- | --- | --- |
| `arm64-v8a` | `aarch64-linux-android` | `aarch64-linux-android` | `aarch64-linux-android` |
| `armeabi-v7a` | `armv7a-linux-androideabi` | `arm-linux-androideabi` | `arm-linux-androideabi` |
| `x86_64` | `x86_64-linux-android` | `x86_64-linux-android` | `x86_64-linux-android` |
| `x86` | `i686-linux-android` | `i686-linux-android` | `i686-linux-android` |

## Building the APK

    export ANDROID_SDK=/path/to/android-sdk
    export LIBAACS=/path/to/libaacs
    ./build-apk-android.sh

`ANDROID_HOME` is accepted in place of `ANDROID_SDK`.

It reads each ABI from `$LIBAACS/build-<abi>/.libs`, where a plain `make`
leaves the library, and packages what it finds, stripping it on the way in.
The result is `out/libaacs-provider.apk`.

| Variable | Default | |
| --- | --- | --- |
| `ANDROID_SDK` | `$ANDROID_HOME` | required |
| `LIBAACS` | — | required; holds the `build-<abi>` directories |
| `OUT` | `out/` | where the APK is written |
| `MANIFEST` | `AndroidManifest.xml` | |
| `MIN_SDK` | 23 | |
| `TARGET_SDK` | 35 | |
| `VERSION_CODE` | 1 | must increase with every published build |
| `VERSION_NAME` | 0.11.1 | the libaacs version packaged; bump with it |
| `KEYSTORE` | `~/.android/debug.keystore` | see below |
| `KEY_ALIAS` | `androiddebugkey` | |
| `KEYSTORE_PASS` | `android` | |
| `KEY_PASS` | `$KEYSTORE_PASS` | |
| `BUILD_TOOLS` | latest installed | 35 or later |
| `ANDROID_JAR` | latest installed platform | |
| `STRIP` | `llvm-strip` if on `PATH` | skipped if neither is found |
| `READELF` | `readelf` | the NDK's `llvm-readelf` also works |

Every check the script makes is there because the failure it catches is
silent: a misaligned or compressed entry produces an APK that builds,
installs, and looks exactly right until an application tries to open the
library.