#!/bin/sh

# Minimal Tor xcframework builder (no LZMA) targeting arm64 slices only.

set -e

PATH=$PATH:/usr/local/bin:/usr/local/opt/gettext/bin:/usr/local/opt/automake/bin:/usr/local/opt/aclocal/bin:/opt/homebrew/bin

OPENSSL_VERSION="openssl-3.6.0"
LIBEVENT_VERSION="release-2.1.12-stable"
TOR_VERSION="tor-0.4.8.19"
TOR_SEMVER="${TOR_VERSION#tor-}"

cd "$(dirname "$0")"
ROOT="$(pwd -P)"

DEBUG=""

while getopts d flag
do
    case "$flag" in
        d) DEBUG="1";;
    esac
done

shift $((OPTIND - 1))

if [ -z "$DEBUG" ]; then
    BUILDDIR="$(mktemp -d)"
else
    BUILDDIR="$ROOT/build"
    mkdir -p "$BUILDDIR"
fi

echo "Build dir: $BUILDDIR"

if ! MAKE_JOBS=$(sysctl -n hw.logicalcpu_max 2>/dev/null); then
    MAKE_JOBS=1
fi

SIZE_FLAGS="-Os -ffunction-sections -fdata-sections"

build_libssl() {
    SDK=$1
    ARCH=$2
    MIN=$3

    SOURCE="$BUILDDIR/openssl"
    LOG="$BUILDDIR/libssl-$SDK-$ARCH.log"

    if [ ! -d "$SOURCE" ]; then
        echo "- Check out OpenSSL project"
        cd "$BUILDDIR"
        git clone --recursive --shallow-submodules --depth 1 --branch "$OPENSSL_VERSION" https://github.com/openssl/openssl.git >> "$LOG" 2>&1
    fi

    echo "- Build OpenSSL for $ARCH ($SDK)"

    cd "$SOURCE"
    make distclean >> "$LOG" 2>&1 || true

    SDKPATH="$(xcrun --sdk ${SDK} --show-sdk-path)"
    CLANG="$(xcrun --sdk ${SDK} --find clang)"

    CC_FLAGS="-isysroot ${SDKPATH} -arch ${ARCH} -m$SDK-version-min=$MIN $SIZE_FLAGS"

    case "$SDK" in
        iphoneos)
            PLATFORM_FLAGS="no-async enable-ec_nistp_64_gcc_128"
            CONFIG="ios64-xcrun"
            ;;
        iphonesimulator)
            PLATFORM_FLAGS="no-async enable-ec_nistp_64_gcc_128"
            CONFIG="iossimulator-xcrun"
            ;;
        macosx)
            PLATFORM_FLAGS="no-asm enable-ec_nistp_64_gcc_128"
            CONFIG="darwin64-arm64-cc"
            ;;
        *)
            echo "Unsupported SDK: $SDK" >&2
            exit 1
            ;;
    esac

    PLATFORM_FLAGS="$PLATFORM_FLAGS no-zlib no-comp no-ssl3 no-tls1 no-tls1_1 no-dtls no-srp no-psk no-weak-ssl-ciphers no-engine no-ocsp"

    ./Configure \
        no-shared \
        ${PLATFORM_FLAGS} \
        --prefix="$BUILDDIR/$SDK/libssl-$ARCH" \
        "${CONFIG}" \
        CC="$CLANG $CC_FLAGS" \
        >> "$LOG" 2>&1

    make depend >> "$LOG" 2>&1
    make -j"$MAKE_JOBS" build_libs >> "$LOG" 2>&1
    make install_dev >> "$LOG" 2>&1
}

build_libevent() {
    SDK=$1
    ARCH=$2
    MIN=$3

    SOURCE="$BUILDDIR/libevent"
    LOG="$BUILDDIR/libevent-$SDK-$ARCH.log"

    if [ ! -d "$SOURCE" ]; then
        echo "- Check out libevent project"
        cd "$BUILDDIR"
        git clone --recursive --shallow-submodules --depth 1 --branch "$LIBEVENT_VERSION" https://github.com/libevent/libevent.git >> "$LOG" 2>&1
    fi

    echo "- Build libevent for $ARCH ($SDK)"

    cd "$SOURCE"
    make distclean 2>/dev/null 1>/dev/null || true

    if [ ! -f ./configure ]; then
        ./autogen.sh >> "$LOG" 2>&1
    fi

    CLANG="$(xcrun -f --sdk ${SDK} clang)"
    SDKPATH="$(xcrun --sdk ${SDK} --show-sdk-path)"
    DEST="$BUILDDIR/$SDK/libevent-$ARCH"

    CFLAGS="-isysroot ${SDKPATH} -m$SDK-version-min=$MIN $SIZE_FLAGS"
    LDFLAGS="-isysroot ${SDKPATH} -L$DEST"

    ./configure \
        --disable-shared \
        --disable-openssl \
        --disable-libevent-regress \
        --disable-samples \
        --disable-doxygen-html \
        --enable-static \
        --enable-gcc-hardening \
        --disable-debug-mode \
        --prefix="$DEST" \
        CC="$CLANG -arch ${ARCH}" \
        CPP="$CLANG -E -arch ${ARCH}" \
        CFLAGS="$CFLAGS" \
        LDFLAGS="$LDFLAGS" \
        cross_compiling="yes" \
        ac_cv_func_clock_gettime="no" \
        >> "$LOG" 2>&1

    make -j"$MAKE_JOBS" >> "$LOG" 2>&1
    make install >> "$LOG" 2>&1
}

build_libtor_nolzma() {
    SDK=$1
    ARCH=$2
    MIN=$3

    SOURCE="$BUILDDIR/tor"
    LOG="$BUILDDIR/libtor-nolzma-$SDK-$ARCH.log"
    DEST="$BUILDDIR/$SDK/libtor-nolzma-$ARCH"

    if [ ! -d "$SOURCE" ]; then
        echo "- Check out Tor project"
        cd "$BUILDDIR"
        git clone --recursive --shallow-submodules --depth 1 --branch "$TOR_VERSION" https://gitlab.torproject.org/tpo/core/tor.git >> "$LOG" 2>&1
    fi

    echo "- Build libtor-nolzma for $ARCH ($SDK)"

    cd "$SOURCE"
    make distclean 2>/dev/null 1>/dev/null || true

    if git apply --check "$ROOT/Tor/mmap-cache.patch" >> "$LOG" 2>&1; then
        git apply --quiet "$ROOT/Tor/mmap-cache.patch" >> "$LOG" 2>&1
    fi

    if [ ! -f ./configure ]; then
        sed -i'.backup' -e 's/all,error/no-obsolete,error/' autogen.sh
        ./autogen.sh >> "$LOG" 2>&1
        rm autogen.sh && mv autogen.sh.backup autogen.sh
    fi

    CLANG="$(xcrun -f --sdk ${SDK} clang)"
    SDKPATH="$(xcrun --sdk ${SDK} --show-sdk-path)"

    CC_FLAGS="-arch ${ARCH} -isysroot ${SDKPATH} $SIZE_FLAGS"
    CPPFLAGS="-Isrc/core -I$BUILDDIR/$SDK/libssl-$ARCH/include -I$BUILDDIR/$SDK/libevent-$ARCH/include -m$SDK-version-min=$MIN $SIZE_FLAGS"
    LDFLAGS="-lz"

    ./configure \
        --enable-silent-rules \
        --enable-pic \
        --disable-module-relay \
        --disable-module-dirauth \
        --disable-tool-name-check \
        --disable-unittests \
        --enable-static-openssl \
        --enable-static-libevent \
        --disable-asciidoc \
        --disable-system-torrc \
        --disable-linker-hardening \
        --disable-dependency-tracking \
        --disable-manpage \
        --disable-html-manual \
        --disable-gcc-warnings-advisory \
        --enable-lzma=no \
        --disable-zstd \
        --with-libevent-dir="$BUILDDIR/$SDK/libevent-$ARCH" \
        --with-openssl-dir="$BUILDDIR/$SDK/libssl-$ARCH" \
        --prefix="$DEST" \
        CC="$CLANG $CC_FLAGS" \
        CPP="$CLANG -E -arch ${ARCH} -isysroot ${SDKPATH}" \
        CPPFLAGS="$CPPFLAGS" \
        LDFLAGS="$LDFLAGS" \
        cross_compiling="yes" \
        ac_cv_func__NSGetEnviron="no" \
        ac_cv_func_clock_gettime="no" \
        ac_cv_func_getentropy="no" \
        >> "$LOG" 2>&1

    sleep 2
    rm -f src/lib/cc/orconfig.h >> "$LOG" 2>&1
    cp orconfig.h "src/lib/cc/" >> "$LOG" 2>&1

    make libtor.a -j"$MAKE_JOBS" V=1 >> "$LOG" 2>&1

    mkdir -p "$DEST/lib" >> "$LOG" 2>&1
    mkdir -p "$DEST/include" >> "$LOG" 2>&1
    mv libtor.a "$DEST/lib" >> "$LOG" 2>&1
    rsync --archive --include='*.h' -f 'hide,! */' --prune-empty-dirs src/* "$DEST/include" >> "$LOG" 2>&1
    cp orconfig.h "$DEST/include/" >> "$LOG" 2>&1

    mv micro-revision.i "$DEST" >> "$LOG" 2>&1
}

write_framework_plist() {
    SDK=$1
    NAME=$2
    PLIST_PATH=$3

    mkdir -p "$(dirname "$PLIST_PATH")"

    case "$SDK" in
        iphoneos)
            PLATFORM="iPhoneOS"
            MIN_KEY="MinimumOSVersion"
            MIN_VALUE="12.0"
            ;;
        iphonesimulator)
            PLATFORM="iPhoneSimulator"
            MIN_KEY="MinimumOSVersion"
            MIN_VALUE="12.0"
            ;;
        macosx)
            PLATFORM="MacOSX"
            MIN_KEY="LSMinimumSystemVersion"
            MIN_VALUE="10.13"
            ;;
        *)
            PLATFORM="$SDK"
            MIN_KEY="MinimumOSVersion"
            MIN_VALUE=""
            ;;
    esac

    cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$NAME</string>
    <key>CFBundleIdentifier</key>
    <string>org.torproject.$NAME</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$NAME</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>$TOR_SEMVER</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>$PLATFORM</string>
    </array>
    <key>CFBundleVersion</key>
    <string>$TOR_SEMVER</string>
EOF

    if [ -n "$MIN_VALUE" ]; then
        cat >> "$PLIST_PATH" <<EOF
    <key>$MIN_KEY</key>
    <string>$MIN_VALUE</string>
EOF
    fi

    cat >> "$PLIST_PATH" <<EOF
</dict>
</plist>
EOF
}

strip_framework_binary() {
    BINARY=$1
    LOG="$BUILDDIR/framework.log"

    echo "- Strip debug info from $BINARY" >> "$LOG"
    xcrun strip -S "$BINARY" >> "$LOG" 2>&1

    if otool -l "$BINARY" | rg "__DWARF" >/dev/null; then
        echo "ERROR: __DWARF segment still present in $BINARY" >&2
        exit 1
    fi
}

create_framework() {
    SDK=$1

    LOG="$BUILDDIR/framework.log"
    NAME="tor-nolzma"
    DEST="$BUILDDIR/$SDK/$NAME.framework"

    rm -rf "$DEST" >> "$LOG" 2>&1
    if [ "$SDK" = "macosx" ]; then
        VERSION_DIR="$DEST/Versions/A"
        mkdir -p "$VERSION_DIR/Headers" "$VERSION_DIR/Resources" >> "$LOG" 2>&1
        FRAMEWORK_BINARY="$VERSION_DIR/$NAME"
        HEADER_DIR="$VERSION_DIR/Headers"
        RESOURCE_DIR="$VERSION_DIR/Resources"
    else
        mkdir -p "$DEST/Headers" >> "$LOG" 2>&1
        FRAMEWORK_BINARY="$DEST/$NAME"
        HEADER_DIR="$DEST/Headers"
        RESOURCE_DIR="$DEST"
    fi

    libtool -static -o "$FRAMEWORK_BINARY" \
        "$BUILDDIR/$SDK/libssl-arm64/lib/libssl.a" \
        "$BUILDDIR/$SDK/libssl-arm64/lib/libcrypto.a" \
        "$BUILDDIR/$SDK/libevent-arm64/lib/libevent.a" \
        "$BUILDDIR/$SDK/libtor-nolzma-arm64/lib/libtor.a" \
        >> "$LOG" 2>&1

    cp -r "$BUILDDIR/$SDK/libssl-arm64/include/"* "$HEADER_DIR" >> "$LOG" 2>&1
    cp -r "$BUILDDIR/$SDK/libevent-arm64/include/"* "$HEADER_DIR" >> "$LOG" 2>&1
    cp -r "$BUILDDIR/$SDK/libtor-nolzma-arm64/include/"* "$HEADER_DIR" >> "$LOG" 2>&1

    write_framework_plist "$SDK" "$NAME" "$RESOURCE_DIR/Info.plist"

    if [ "$SDK" = "macosx" ]; then
        ln -sfn A "$DEST/Versions/Current"
        ln -sfn "Versions/Current/$NAME" "$DEST/$NAME"
        ln -sfn "Versions/Current/Headers" "$DEST/Headers"
        ln -sfn "Versions/Current/Resources" "$DEST/Resources"
    fi

    strip_framework_binary "$FRAMEWORK_BINARY"
}

build_target() {
    SDK=$1
    MIN=$2

    build_libssl "$SDK" arm64 "$MIN"
    build_libevent "$SDK" arm64 "$MIN"
    build_libtor_nolzma "$SDK" arm64 "$MIN"
    create_framework "$SDK"
}

build_target iphoneos 12.0
build_target iphonesimulator 12.0
build_target macosx 10.13

echo "- Create xcframework"

LOG="$BUILDDIR/framework.log"
rm -rf "$ROOT/tor-nolzma.xcframework" "$ROOT/tor-nolzma.xcframework.zip" >> "$LOG" 2>&1

xcodebuild -create-xcframework \
    -framework "$BUILDDIR/iphoneos/tor-nolzma.framework" \
    -framework "$BUILDDIR/iphonesimulator/tor-nolzma.framework" \
    -framework "$BUILDDIR/macosx/tor-nolzma.framework" \
    -output "$ROOT/tor-nolzma.xcframework" >> "$LOG" 2>&1

cd "$ROOT"
zip -r -9 "tor-nolzma.xcframework.zip" "tor-nolzma.xcframework" >> "$LOG" 2>&1
shasum -a 256 "tor-nolzma.xcframework.zip"

if [ -z "$DEBUG" ]; then
    rm -rf "$BUILDDIR"
fi
