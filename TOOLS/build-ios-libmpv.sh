#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_ARCH="${IOS_ARCH:-arm64}"
IOS_MIN_VERSION="${IOS_MIN_VERSION:-13.0}"
FFMPEG_BUILD_ROOT="${FFMPEG_BUILD_ROOT:-/Users/jvrcruz/Documents/FFmpeg/build/ios}"
BUILD_ROOT="${BUILD_DIR:-${ROOT_DIR}/build}"
OUT_ROOT="${INSTALL_PREFIX:-${ROOT_DIR}/out}"
PKG_CONFIG_BIN="${PKG_CONFIG:-pkg-config}"

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

build_targets=(iphoneos iphonesimulator)

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
        echo "git is required to fetch ${name}" >&2
        exit 1
    fi

    mkdir -p "${ROOT_DIR}/subprojects"
    tmpdir="$(mktemp -d "${ROOT_DIR}/subprojects/${name}.XXXXXX")"
    rm -rf "${tmpdir}"

    echo "Fetching ${name} ${version}..."
    if ! git clone --depth=1 --branch "${version}" --recursive "${repo}" "${tmpdir}"; then
        rm -rf "${tmpdir}"
        exit 1
    fi

    mv "${tmpdir}" "${subproject_dir}"
}

check_ffmpeg_prefix() {
    local prefix="$1"
    local expected_platform="$2"
    local expected_name="$3"
    local lib member platform tmpdir

    if [[ ! -d "${prefix}" ]]; then
        echo "Missing FFmpeg prefix: ${prefix}" >&2
        exit 1
    fi

    for lib in libavcodec libavfilter libavformat libavutil libswresample libswscale; do
        if [[ ! -f "${prefix}/lib/${lib}.a" ]]; then
            echo "Missing FFmpeg library: ${prefix}/lib/${lib}.a" >&2
            exit 1
        fi

        member="$(ar -t "${prefix}/lib/${lib}.a" | grep -Ev '^(__\.SYMDEF|SYMDEF|/)' | head -n 1)"
        if [[ -z "${member}" ]]; then
            echo "Could not inspect ${prefix}/lib/${lib}.a" >&2
            exit 1
        fi

        tmpdir="$(mktemp -d)"
        (cd "${tmpdir}" && ar -x "${prefix}/lib/${lib}.a" "${member}")
        platform="$(otool -l "${tmpdir}/${member}" | awk '/platform / { print $2; exit }')"
        rm -rf "${tmpdir}"

        if [[ "${platform}" != "${expected_platform}" ]]; then
            cat >&2 <<EOF
${prefix}/lib/${lib}.a is not built for ${expected_name}.
Found Mach-O platform ${platform:-unknown}; expected ${expected_platform}.
EOF
            exit 1
        fi
    done
}

build_one() {
    local platform="$1"
    local sdk_name cpu_family cpu clang_target macho_platform macho_name
    local ffmpeg_prefix build_dir install_prefix sdk_path clang ar strip pkg_wrapper cross_file

    case "${platform}" in
        iphoneos)
            sdk_name="iphoneos"
            cpu_family="aarch64"
            cpu="arm64"
            clang_target="${IOS_ARCH}-apple-ios${IOS_MIN_VERSION}"
            macho_platform="2"
            macho_name="iOS"
            ;;
        iphonesimulator)
            sdk_name="iphonesimulator"
            macho_platform="7"
            macho_name="iOS Simulator"
            case "${IOS_ARCH}" in
                arm64)
                    cpu_family="aarch64"
                    cpu="arm64"
                    clang_target="arm64-apple-ios${IOS_MIN_VERSION}-simulator"
                    ;;
                x86_64)
                    cpu_family="x86_64"
                    cpu="x86_64"
                    clang_target="x86_64-apple-ios${IOS_MIN_VERSION}-simulator"
                    ;;
                *)
                    echo "Unsupported simulator IOS_ARCH=${IOS_ARCH}" >&2
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo "Unsupported platform: ${platform}" >&2
            exit 1
            ;;
    esac

    ffmpeg_prefix="${FFMPEG_BUILD_ROOT}/${platform}-${IOS_ARCH}"
    check_ffmpeg_prefix "${ffmpeg_prefix}" "${macho_platform}" "${macho_name}"

    build_dir="${BUILD_ROOT}/${platform}-${IOS_ARCH}"
    install_prefix="${OUT_ROOT}/${platform}-${IOS_ARCH}"
    sdk_path="$(xcrun --sdk "${sdk_name}" --show-sdk-path)"
    clang="$(xcrun --sdk "${sdk_name}" --find clang)"
    ar="$(xcrun --sdk "${sdk_name}" --find ar)"
    strip="$(xcrun --sdk "${sdk_name}" --find strip)"

    mkdir -p "${build_dir}" "${install_prefix}"

    pkg_wrapper="${build_dir}/pkg-config-ios"
    cat >"${pkg_wrapper}" <<EOF
#!/usr/bin/env bash
export PKG_CONFIG_LIBDIR="${ffmpeg_prefix}/lib/pkgconfig"
export PKG_CONFIG_PATH="${ffmpeg_prefix}/lib/pkgconfig"
exec "${PKG_CONFIG_BIN}" "\$@"
EOF
    chmod +x "${pkg_wrapper}"

    cross_file="${build_dir}/ios-cross.ini"
    cat >"${cross_file}" <<EOF
[binaries]
c = '${clang}'
objc = '${clang}'
cpp = '${clang}++'
ar = '${ar}'
strip = '${strip}'
pkg-config = '${pkg_wrapper}'

[host_machine]
system = 'darwin'
cpu_family = '${cpu_family}'
cpu = '${cpu}'
endian = 'little'

[properties]
needs_exe_wrapper = true

[built-in options]
c_args = ['-target', '${clang_target}', '-isysroot', '${sdk_path}', '-I${ffmpeg_prefix}/include']
objc_args = ['-target', '${clang_target}', '-isysroot', '${sdk_path}', '-I${ffmpeg_prefix}/include']
cpp_args = ['-target', '${clang_target}', '-isysroot', '${sdk_path}', '-I${ffmpeg_prefix}/include']
c_link_args = ['-target', '${clang_target}', '-isysroot', '${sdk_path}', '-L${ffmpeg_prefix}/lib']
objc_link_args = ['-target', '${clang_target}', '-isysroot', '${sdk_path}', '-L${ffmpeg_prefix}/lib']
cpp_link_args = ['-target', '${clang_target}', '-isysroot', '${sdk_path}', '-L${ffmpeg_prefix}/lib']
EOF

    meson_opts=(
        --cross-file "${cross_file}"
        --prefix "${install_prefix}"
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

    if [[ ! -f "${build_dir}/build.ninja" ]]; then
        meson setup "${build_dir}" "${ROOT_DIR}" "${meson_opts[@]}"
    else
        meson setup --reconfigure "${build_dir}" "${ROOT_DIR}" "${meson_opts[@]}"
    fi

    meson compile -C "${build_dir}" mpv
    meson install -C "${build_dir}" --tags runtime,devel

    echo "Built ${platform} for ${IOS_ARCH}"
    echo "Installed to ${install_prefix}"
}

fetch_subproject "libplacebo" "${LIBPLACEBO_VERSION}" "${LIBPLACEBO_REPO}"
fetch_subproject "freetype2" "${FREETYPE_VERSION}" "${FREETYPE_REPO}"
fetch_subproject "fribidi" "${FRIBIDI_VERSION}" "${FRIBIDI_REPO}"
fetch_subproject "harfbuzz" "${HARFBUZZ_VERSION}" "${HARFBUZZ_REPO}"
fetch_subproject "libass" "${LIBASS_VERSION}" "${LIBASS_REPO}"

for platform in "${build_targets[@]}"; do
    build_one "${platform}"
done
