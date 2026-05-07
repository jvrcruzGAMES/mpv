#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IOS_PLATFORM="${IOS_PLATFORM:-iphoneos}"
IOS_ARCH="${IOS_ARCH:-arm64}"
IOS_MIN_VERSION="${IOS_MIN_VERSION:-13.0}"
FFMPEG_PREFIX="${FFMPEG_PREFIX:-/Users/jvrcruz/Documents/FFmpeg/build/ios/iphoneos-arm64}"
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build/ios-${IOS_PLATFORM}-${IOS_ARCH}}"
INSTALL_PREFIX="${INSTALL_PREFIX:-${ROOT_DIR}/out/ios-${IOS_PLATFORM}-${IOS_ARCH}}"
LIBPLACEBO_VERSION="${LIBPLACEBO_VERSION:-v7.360.1}"
LIBPLACEBO_REPO="${LIBPLACEBO_REPO:-https://code.videolan.org/videolan/libplacebo.git}"
LIBASS_VERSION="${LIBASS_VERSION:-0.17.4}"
LIBASS_REPO="${LIBASS_REPO:-https://github.com/libass/libass.git}"
FREETYPE_VERSION="${FREETYPE_VERSION:-VER-2-13-3}"
FREETYPE_REPO="${FREETYPE_REPO:-https://gitlab.freedesktop.org/freetype/freetype.git}"
FRIBIDI_VERSION="${FRIBIDI_VERSION:-v1.0.16}"
FRIBIDI_REPO="${FRIBIDI_REPO:-https://github.com/fribidi/fribidi.git}"
HARFBUZZ_VERSION="${HARFBUZZ_VERSION:-10.2.0}"
HARFBUZZ_REPO="${HARFBUZZ_REPO:-https://github.com/harfbuzz/harfbuzz.git}"

case "${IOS_PLATFORM}" in
    iphoneos)
        SDK_NAME="iphoneos"
        CPU_FAMILY="aarch64"
        CPU="arm64"
        CLANG_TARGET="${IOS_ARCH}-apple-ios${IOS_MIN_VERSION}"
        EXPECTED_MACHO_PLATFORM="2"
        EXPECTED_MACHO_PLATFORM_NAME="iOS"
        ;;
    iphonesimulator)
        SDK_NAME="iphonesimulator"
        EXPECTED_MACHO_PLATFORM="7"
        EXPECTED_MACHO_PLATFORM_NAME="iOS Simulator"
        case "${IOS_ARCH}" in
            arm64)
                CPU_FAMILY="aarch64"
                CPU="arm64"
                CLANG_TARGET="arm64-apple-ios${IOS_MIN_VERSION}-simulator"
                ;;
            x86_64)
                CPU_FAMILY="x86_64"
                CPU="x86_64"
                CLANG_TARGET="x86_64-apple-ios${IOS_MIN_VERSION}-simulator"
                ;;
            *)
                echo "Unsupported simulator IOS_ARCH=${IOS_ARCH}" >&2
                exit 1
                ;;
        esac
        ;;
    *)
        echo "Unsupported IOS_PLATFORM=${IOS_PLATFORM}; use iphoneos or iphonesimulator" >&2
        exit 1
        ;;
esac

check_static_library_platform() {
    local lib="$1"
    local member platform tmpdir

    if [[ ! -f "${lib}" ]]; then
        echo "Missing required static library: ${lib}" >&2
        exit 1
    fi

    member="$(ar -t "${lib}" | grep -Ev '^(__\.SYMDEF|SYMDEF|/)' | head -n 1)"
    if [[ -z "${member}" ]]; then
        echo "Could not inspect ${lib}: archive has no object members" >&2
        exit 1
    fi

    tmpdir="$(mktemp -d)"
    (cd "${tmpdir}" && ar -x "${lib}" "${member}")
    platform="$(otool -l "${tmpdir}/${member}" | awk '/platform / { print $2; exit }')"
    rm -rf "${tmpdir}"

    if [[ "${platform}" != "${EXPECTED_MACHO_PLATFORM}" ]]; then
        cat >&2 <<EOF
${lib} is not built for ${EXPECTED_MACHO_PLATFORM_NAME}.
Found Mach-O platform ${platform:-unknown}; expected ${EXPECTED_MACHO_PLATFORM}.

Build or install FFmpeg for ${EXPECTED_MACHO_PLATFORM_NAME} under ${FFMPEG_PREFIX}
and make sure ${FFMPEG_PREFIX}/lib/pkgconfig points at those iOS libraries.
EOF
        exit 1
    fi
}

for ffmpeg_lib in libavcodec libavfilter libavformat libavutil libswresample libswscale; do
    check_static_library_platform "${FFMPEG_PREFIX}/lib/${ffmpeg_lib}.a"
done

fetch_subproject() {
    local name="$1"
    local version="$2"
    local repo="$3"
    local subproject_dir="${ROOT_DIR}/subprojects/${name}"
    local tmpdir

    if [[ -f "${subproject_dir}/meson.build" ]]; then
        return
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo "git is required to fetch ${name} for the self-contained iOS build" >&2
        exit 1
    fi

    mkdir -p "${ROOT_DIR}/subprojects"
    tmpdir="$(mktemp -d "${ROOT_DIR}/subprojects/${name}.XXXXXX")"
    rm -rf "${tmpdir}"

    echo "Fetching ${name} ${version} for the iOS Meson subproject..."
    if ! git clone --depth=1 --branch "${version}" --recursive \
        "${repo}" "${tmpdir}"; then
        rm -rf "${tmpdir}"
        exit 1
    fi

    mv "${tmpdir}" "${subproject_dir}"
}

fetch_subproject "libplacebo" "${LIBPLACEBO_VERSION}" "${LIBPLACEBO_REPO}"
fetch_subproject "freetype2" "${FREETYPE_VERSION}" "${FREETYPE_REPO}"
fetch_subproject "fribidi" "${FRIBIDI_VERSION}" "${FRIBIDI_REPO}"
fetch_subproject "harfbuzz" "${HARFBUZZ_VERSION}" "${HARFBUZZ_REPO}"
fetch_subproject "libass" "${LIBASS_VERSION}" "${LIBASS_REPO}"

SDK_PATH="$(xcrun --sdk "${SDK_NAME}" --show-sdk-path)"
CLANG="$(xcrun --sdk "${SDK_NAME}" --find clang)"
AR="$(xcrun --sdk "${SDK_NAME}" --find ar)"
STRIP="$(xcrun --sdk "${SDK_NAME}" --find strip)"
PKG_CONFIG="${PKG_CONFIG:-pkg-config}"

mkdir -p "${BUILD_DIR}"

PKG_CONFIG_WRAPPER="${BUILD_DIR}/pkg-config-ios"
cat >"${PKG_CONFIG_WRAPPER}" <<EOF
#!/usr/bin/env bash
export PKG_CONFIG_LIBDIR="${FFMPEG_PREFIX}/lib/pkgconfig"
export PKG_CONFIG_PATH="${FFMPEG_PREFIX}/lib/pkgconfig"
exec "${PKG_CONFIG}" "\$@"
EOF
chmod +x "${PKG_CONFIG_WRAPPER}"

CROSS_FILE="${BUILD_DIR}/ios-cross.ini"
cat >"${CROSS_FILE}" <<EOF
[binaries]
c = '${CLANG}'
objc = '${CLANG}'
cpp = '${CLANG}++'
ar = '${AR}'
strip = '${STRIP}'
pkg-config = '${PKG_CONFIG_WRAPPER}'

[host_machine]
system = 'darwin'
cpu_family = '${CPU_FAMILY}'
cpu = '${CPU}'
endian = 'little'

[properties]
needs_exe_wrapper = true

[built-in options]
c_args = ['-target', '${CLANG_TARGET}', '-isysroot', '${SDK_PATH}', '-I${FFMPEG_PREFIX}/include']
objc_args = ['-target', '${CLANG_TARGET}', '-isysroot', '${SDK_PATH}', '-I${FFMPEG_PREFIX}/include']
cpp_args = ['-target', '${CLANG_TARGET}', '-isysroot', '${SDK_PATH}', '-I${FFMPEG_PREFIX}/include']
c_link_args = ['-target', '${CLANG_TARGET}', '-isysroot', '${SDK_PATH}', '-L${FFMPEG_PREFIX}/lib']
objc_link_args = ['-target', '${CLANG_TARGET}', '-isysroot', '${SDK_PATH}', '-L${FFMPEG_PREFIX}/lib']
cpp_link_args = ['-target', '${CLANG_TARGET}', '-isysroot', '${SDK_PATH}', '-L${FFMPEG_PREFIX}/lib']
EOF

COMMON_OPTIONS=(
    --cross-file "${CROSS_FILE}"
    --prefix "${INSTALL_PREFIX}"
    -Ddefault_library=static
    -Dprefer_static=true
    -Dlibmpv=true
    -Dcplayer=false
    -Dtests=false
    -Dfuzzers=false
    -Dbuild-date=false
    -Dgpl=true
    -Dmanpage-build=disabled
    -Dhtml-build=disabled
    -Dpdf-build=disabled
    -Dswift-build=disabled
    -Dmacos-cocoa-cb=disabled
    -Dmacos-media-player=disabled
    -Dmacos-touchbar=disabled
    -Dcocoa=disabled
    -Dcoreaudio=disabled
    -Davfoundation=disabled
    -Daudiounit=enabled
    -Dgl=enabled
    -Dplain-gl=enabled
    -Dios-gl=enabled
    -Dvideotoolbox-gl=enabled
    -Dvideotoolbox-pl=disabled
    -Dvulkan=disabled
    -Dshaderc=disabled
    -Dspirv-cross=disabled
    -Dfreetype2:brotli=disabled
    -Dfreetype2:bzip2=disabled
    -Dfreetype2:harfbuzz=disabled
    -Dfreetype2:png=disabled
    -Dfreetype2:tests=disabled
    -Dfreetype2:zlib=none
    -Dfribidi:docs=false
    -Dfribidi:tests=false
    -Dharfbuzz:tests=disabled
    -Dharfbuzz:cairo=disabled
    -Dharfbuzz:coretext=disabled
    -Dharfbuzz:docs=disabled
    -Dharfbuzz:freetype=disabled
    -Dharfbuzz:glib=disabled
    -Dharfbuzz:gobject=disabled
    -Dharfbuzz:icu=disabled
    -Dlibass:test=disabled
    -Dlibass:compare=disabled
    -Dlibass:profile=disabled
    -Dlibass:fuzz=disabled
    -Dlibass:checkasm=disabled
    -Dlibass:fontconfig=disabled
    -Dlibass:directwrite=disabled
    -Dlibass:coretext=enabled
    -Dlibass:asm=disabled
    -Dlibass:libunibreak=disabled
    -Dlibplacebo:demos=false
    -Dlibplacebo:tests=false
    -Dlibplacebo:bench=false
    -Dlibplacebo:fuzz=false
    -Dlibplacebo:vulkan=disabled
    -Dlibplacebo:vk-proc-addr=disabled
    -Dlibplacebo:opengl=enabled
    -Dlibplacebo:d3d11=disabled
    -Dlibplacebo:glslang=disabled
    -Dlibplacebo:shaderc=disabled
    -Dlibplacebo:lcms=disabled
    -Dlibplacebo:libdovi=disabled
    -Dlibplacebo:unwind=disabled
    -Dlibavdevice=disabled
    -Dlua=disabled
    -Djavascript=disabled
    -Dlibarchive=disabled
    -Dlibbluray=disabled
    -Dcdda=disabled
    -Ddvdnav=disabled
    -Dlcms2=disabled
    -Djpeg=disabled
    -Drubberband=disabled
    -Duchardet=disabled
    -Dzimg=disabled
    -Dsdl2-audio=disabled
    -Dsdl2-video=disabled
    -Dsdl2-gamepad=disabled
    -Dopenal=disabled
    -Djack=disabled
    -Dvapoursynth=disabled
    -Dsubrandr=disabled
    -Dx11=disabled
    -Dx11-clipboard=disabled
    -Dwayland=disabled
    -Ddrm=disabled
    -Dgbm=disabled
    -Degl=disabled
    -Dvaapi=disabled
    -Dvdpau=disabled
    -Dcaca=disabled
    -Dsixel=disabled
)

if [[ ! -f "${BUILD_DIR}/build.ninja" ]]; then
    meson setup "${BUILD_DIR}" "${ROOT_DIR}" "${COMMON_OPTIONS[@]}"
else
    meson setup --reconfigure "${BUILD_DIR}" "${ROOT_DIR}" "${COMMON_OPTIONS[@]}"
fi

meson compile -C "${BUILD_DIR}" mpv
meson install -C "${BUILD_DIR}" --tags runtime,devel

echo "Built ${BUILD_DIR}/libmpv.a"
echo "Installed headers and pkg-config data under ${INSTALL_PREFIX}"
