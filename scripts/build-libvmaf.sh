#!/bin/bash
# Build libvmaf from source as a universal static library.
#
# Output:
#   .cache/libvmaf-${LIBVMAF_VERSION}/out/lib/libvmaf.a       (universal: arm64 + x86_64)
#   .cache/libvmaf-${LIBVMAF_VERSION}/out/include/libvmaf/*.h (headers)
#
# Idempotent: re-running is a no-op when the universal lib already exists.
#
# Required host tools (build-time only — never bundled with the app):
#   meson, ninja, nasm. Install via `brew install meson ninja nasm`.
#
# Override the libvmaf version with `LIBVMAF_VERSION=x.y.z ./build-libvmaf.sh`.

set -euo pipefail

LIBVMAF_VERSION="${LIBVMAF_VERSION:-3.1.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CACHE_ROOT="$ROOT/.cache/libvmaf-$LIBVMAF_VERSION"
SRC_DIR="$CACHE_ROOT/src"
OUT_DIR="$CACHE_ROOT/out"
UNIVERSAL_LIB="$OUT_DIR/lib/libvmaf.a"
INCLUDE_DIR="$OUT_DIR/include"

# Already built? Skip.
if [ -f "$UNIVERSAL_LIB" ] && [ -d "$INCLUDE_DIR/libvmaf" ]; then
    echo "libvmaf $LIBVMAF_VERSION already built: $UNIVERSAL_LIB"
    exit 0
fi

# Verify build prerequisites.
missing=()
for tool in meson ninja nasm; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: missing host build tool(s): ${missing[*]}" >&2
    echo "Install via: brew install ${missing[*]}" >&2
    exit 1
fi

# Fetch source.
if [ ! -f "$SRC_DIR/meson.build" ]; then
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    echo "Fetching libvmaf $LIBVMAF_VERSION..."
    curl -fsSL "https://github.com/Netflix/vmaf/archive/refs/tags/v${LIBVMAF_VERSION}.tar.gz" \
        | tar -xz -C "$SRC_DIR" --strip-components=1
fi

# libvmaf's Meson tree lives under `libvmaf/` inside the vmaf repo.
LIBVMAF_SRC="$SRC_DIR/libvmaf"
if [ ! -f "$LIBVMAF_SRC/meson.build" ]; then
    echo "ERROR: expected libvmaf source at $LIBVMAF_SRC" >&2
    exit 1
fi

build_arch() {
    local arch="$1"
    local builddir="$CACHE_ROOT/build-$arch"
    local crossfile="$CACHE_ROOT/cross-$arch.ini"

    local cpu_family
    if [ "$arch" = "arm64" ]; then cpu_family=aarch64; else cpu_family=x86_64; fi

    cat > "$crossfile" <<EOF
[binaries]
c       = ['xcrun', '--sdk', 'macosx', 'clang']
cpp     = ['xcrun', '--sdk', 'macosx', 'clang++']
strip   = ['xcrun', '--sdk', 'macosx', 'strip']
ar      = ['xcrun', '--sdk', 'macosx', 'ar']
ranlib  = ['xcrun', '--sdk', 'macosx', 'ranlib']
nasm    = '$(command -v nasm)'

[built-in options]
c_args         = ['-arch', '$arch', '-mmacosx-version-min=14.0', '-O3', '-fno-stack-check']
cpp_args       = ['-arch', '$arch', '-mmacosx-version-min=14.0', '-O3', '-fno-stack-check']
c_link_args    = ['-arch', '$arch', '-mmacosx-version-min=14.0']
cpp_link_args  = ['-arch', '$arch', '-mmacosx-version-min=14.0']

[host_machine]
system     = 'darwin'
cpu_family = '$cpu_family'
cpu        = '$arch'
endian     = 'little'
EOF

    if [ ! -f "$builddir/build.ninja" ]; then
        rm -rf "$builddir"
        echo "Configuring libvmaf for $arch..."
        meson setup "$builddir" "$LIBVMAF_SRC" \
            --cross-file "$crossfile" \
            --buildtype release \
            --default-library static \
            -Denable_tests=false \
            -Denable_docs=false \
            -Denable_avx512=false \
            -Dbuilt_in_models=true
    fi

    echo "Building libvmaf for $arch..."
    ninja -C "$builddir"
}

build_arch arm64
build_arch x86_64

# Combine into a universal static lib.
mkdir -p "$OUT_DIR/lib"
ARM64_A="$CACHE_ROOT/build-arm64/src/libvmaf.a"
X8664_A="$CACHE_ROOT/build-x86_64/src/libvmaf.a"
[ -f "$ARM64_A" ] || ARM64_A="$CACHE_ROOT/build-arm64/src/libvmaf/libvmaf.a"
[ -f "$X8664_A" ] || X8664_A="$CACHE_ROOT/build-x86_64/src/libvmaf/libvmaf.a"

if [ ! -f "$ARM64_A" ] || [ ! -f "$X8664_A" ]; then
    echo "ERROR: libvmaf.a not found at expected path; inspect $CACHE_ROOT/build-*" >&2
    find "$CACHE_ROOT" -name 'libvmaf.a' >&2 || true
    exit 1
fi

lipo -create "$ARM64_A" "$X8664_A" -output "$UNIVERSAL_LIB"

# Copy headers (from the source tree — they're arch-independent).
mkdir -p "$INCLUDE_DIR"
rm -rf "$INCLUDE_DIR/libvmaf"
cp -R "$LIBVMAF_SRC/include/libvmaf" "$INCLUDE_DIR/libvmaf"

echo
echo "Universal libvmaf static library:"
lipo -info "$UNIVERSAL_LIB"
echo "  $UNIVERSAL_LIB"
echo "  $INCLUDE_DIR/libvmaf"
