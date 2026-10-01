#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Surface Pro 7 rear-camera installer
#
# v0.1 target:
#   Microsoft Surface Pro 7 (without Plus)
#   Fedora Workstation 43
#   x86_64
#   kernel 6.19.8-3.surface.fc43.x86_64
#
# The default mode targets the exact configuration on which the rear OV8865
# camera stack was validated. --allow-untested-distro permits deliberate
# experiments on other distributions/kernel versions while retaining the
# Surface Pro 7, x86_64, IPU4P, kernel-build-tree and Secure Boot checks.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

EXPECTED_KERNEL="6.19.8-3.surface.fc43.x86_64"
EXPECTED_FEDORA="43"
EXPECTED_ARCH="x86_64"

LINUX_COMMIT="86818b2e7d9c22225b15f2ae91d3f35c4a07dfd9"
LINUX_REF="refs/tags/v6.19.8"
IPU4_COMMIT="aa0043f3649c3bff9247d5f99de5d164c3cdcc75"
LIBCAMERA_COMMIT="191e202178f02430b5942397c70d215cdd2056fa"
PIPEWIRE_COMMIT="255541eac34370e312f0c5c8c18e46dc1911352f"
V4L2LOOPBACK_COMMIT="0f9ee86760b7f2bea174b7e3e7a1d38845da0ab4"
V4L2LOOPBACK_REF="refs/tags/v0.15.4"
FIRMWARE_COMMIT="4ea36123f12e8eafe4f12017614e7b642feb5430"

FIRMWARE_SHA256="ff2c36cc81a5c726508b22970c2e2538ff06107dc5a72c93401403c227e5157f"

KVER="$(uname -r)"
KDIR="/lib/modules/$KVER/build"
MODULE_DEST="/lib/modules/$KVER/updates/extra"

WORK=""
BACKUP_ROOT=""

log()
{
    printf '\n============================================================\n'
    printf ' %s\n' "$*"
    printf '============================================================\n'
}

die()
{
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

cleanup()
{
    if [[ -n "${WORK:-}" && -d "$WORK" ]]; then
        rm -rf "$WORK"
    fi
}

trap cleanup EXIT

# SP7_BUILD_ONLY_MODE_V1
BUILD_ONLY=0
ALLOW_UNTESTED_DISTRO=0

for arg in "$@"; do
    case "$arg" in
        --build-only)
            BUILD_ONLY=1
            ;;
        --allow-untested-distro)
            ALLOW_UNTESTED_DISTRO=1
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--build-only] [--allow-untested-distro]

  --build-only
      Build and verify without installing system files.

  --allow-untested-distro
      Permit deliberate testing outside the known-good Fedora 43/kernel
      combination. Hardware and safety checks remain enforced.
EOF
            exit 0
            ;;
        *)
            die "Usage: $0 [--build-only] [--allow-untested-distro]"
            ;;
    esac
done

repo_for_section()
{
    local section="$1"

    awk -v section="$section:" '
        $0 == section {
            active = 1
            next
        }

        active && ($1 == "repository:" || $1 == "upstream:") {
            print $2
            exit
        }

        active && /^[[:alnum:]][^[:space:]]*:/ {
            exit
        }
    ' "$ROOT/docs/source-bases.txt"
}

fetch_commit()
{
    local url="$1"
    local commit="$2"
    local dest="$3"

    mkdir -p "$dest"

    git -C "$dest" init -q
    git -C "$dest" remote add origin "$url"

    git -C "$dest" fetch \
        --quiet \
        --depth=1 \
        origin "$commit"

    git -C "$dest" checkout \
        --quiet \
        --detach FETCH_HEAD

    local actual
    actual="$(git -C "$dest" rev-parse HEAD)"

    [[ "$actual" == "$commit" ]] \
        || die "Wrong source commit in $dest: $actual"
}

fetch_ref_commit()
{
    local url="$1"
    local ref="$2"
    local commit="$3"
    local dest="$4"

    mkdir -p "$dest"

    git -C "$dest" init -q
    git -C "$dest" remote add origin "$url"

    git -C "$dest" fetch \
        --quiet \
        --depth=1 \
        origin "$ref:$ref"

    git -C "$dest" checkout \
        --quiet \
        --detach "$ref^{commit}"

    local actual
    actual="$(git -C "$dest" rev-parse HEAD)"

    [[ "$actual" == "$commit" ]] \
        || die "Wrong source commit for $ref in $dest: $actual"
}

apply_patch()
{
    local tree="$1"
    local patch="$2"

    [[ -s "$patch" ]] \
        || die "Patch missing: $patch"

    git -C "$tree" apply \
        --check \
        --whitespace=nowarn \
        "$patch"

    git -C "$tree" apply \
        --whitespace=nowarn \
        "$patch"
}

check_vermagic()
{
    local module="$1"

    local vm
    vm="$(modinfo -F vermagic "$module" 2>/dev/null || true)"

    [[ "$vm" == "$KVER "* ]] \
        || die "Wrong vermagic for $module: $vm"
}

backup_system_file()
{
    local path="$1"

    sudo test -e "$path" || return 0

    local target="$BACKUP_ROOT$path"

    sudo mkdir -p "$(dirname "$target")"

    if ! sudo test -e "$target"; then
        sudo cp -a "$path" "$target"
    fi
}

install_system_file()
{
    local src="$1"
    local dst="$2"
    local mode="$3"

    backup_system_file "$dst"

    sudo install \
        -D \
        -m "$mode" \
        "$src" \
        "$dst"
}

# -------------------------------------------------------------------------
# Preconditions
# -------------------------------------------------------------------------

log "Surface Pro 7 camera installer – preflight"

[[ $EUID -ne 0 ]] \
    || die "Run this installer as your normal desktop user, not with sudo."

[[ -f /etc/os-release ]] \
    || die "/etc/os-release is missing."

# shellcheck disable=SC1091
source /etc/os-release

KNOWN_GOOD_DISTRO=0

if [[ "${ID:-}" == "fedora" && "${VERSION_ID:-}" == "$EXPECTED_FEDORA" ]]; then
    KNOWN_GOOD_DISTRO=1
    echo "PASS: known-good distribution: Fedora $EXPECTED_FEDORA"
elif [[ "$ALLOW_UNTESTED_DISTRO" -eq 1 ]]; then
    printf 'WARNING: untested distribution: %s\n' \
        "${PRETTY_NAME:-${ID:-unknown}}"
    echo "Continuing because --allow-untested-distro was requested."
    echo "Automatic distribution package installation is disabled."
else
    die "Untested distribution: ${PRETTY_NAME:-${ID:-unknown}}. Use --allow-untested-distro only for deliberate experimental testing."
fi

[[ "$(uname -m)" == "$EXPECTED_ARCH" ]] \
    || die "This release supports x86_64 only."

if [[ "$KVER" == "$EXPECTED_KERNEL" ]]; then
    echo "PASS: known-good kernel: $KVER"
elif [[ "$ALLOW_UNTESTED_DISTRO" -eq 1 ]]; then
    printf 'WARNING: untested kernel: %s\n' "$KVER"
    printf 'Known-good kernel: %s\n' "$EXPECTED_KERNEL"
    echo "Continuing experimentally; external modules must build against this kernel."
else
    die "Untested kernel: $KVER. Expected $EXPECTED_KERNEL. Use --allow-untested-distro only for deliberate experimental testing."
fi

KNOWN_GOOD_CONFIG=0

if [[ "$KNOWN_GOOD_DISTRO" -eq 1 && "$KVER" == "$EXPECTED_KERNEL" ]]; then
    KNOWN_GOOD_CONFIG=1
else
    echo "WARNING: this is not the complete known-good Fedora/kernel combination."
    echo "Experimental mode: automatic distribution package installation is disabled."
fi

PRODUCT="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"

[[ "$PRODUCT" == *"Surface Pro 7"* ]] \
    || die "This does not identify as a Surface Pro 7: $PRODUCT"

[[ "$PRODUCT" != *"Surface Pro 7+"* ]] \
    || die "Surface Pro 7+ is not supported by this release."

command -v lspci >/dev/null 2>&1 \
    || die "lspci is required."

lspci -nn | grep -qi '8086:8a19' \
    || die "Intel IPU4P PCI device 8086:8a19 was not found."

if [[ "$BUILD_ONLY" -eq 0 ]]; then
    sudo -v
fi

# -------------------------------------------------------------------------
# Build dependencies
# -------------------------------------------------------------------------

if [[ "$BUILD_ONLY" -eq 1 || "$KNOWN_GOOD_CONFIG" -eq 0 ]]; then
    if [[ "$BUILD_ONLY" -eq 1 ]]; then
        log "Checking build-only dependencies"
    else
        log "Checking dependencies for untested distribution"
        echo "Automatic package installation is disabled in experimental mode."
    fi

    for cmd in \
        git \
        gcc \
        g++ \
        cc \
        make \
        cmake \
        meson \
        ninja \
        pkg-config \
        python3 \
        modinfo \
        lspci \
        mokutil \
        readelf \
        ldd \
        sha256sum
    do
        command -v "$cmd" >/dev/null 2>&1 \
            || die "Required build dependency is missing: $cmd"
    done

    if [[ "$BUILD_ONLY" -eq 0 ]]; then
        for cmd in \
            sudo \
            git-lfs \
            depmod \
            systemctl \
            gst-launch-1.0 \
            gst-inspect-1.0
        do
            command -v "$cmd" >/dev/null 2>&1 \
                || die "Required experimental-install dependency is missing: $cmd"
        done

        python3 -c 'import jinja2, ply, yaml' >/dev/null 2>&1 \
            || die "Required Python modules are missing: jinja2, ply and/or yaml."

        pkg-config --exists yaml-0.1 \
            || die "Required libyaml development files are missing (pkg-config: yaml-0.1)."

        pkg-config --exists libevent \
            || die "Required libevent development files are missing (pkg-config: libevent)."

        for gst_element in pipewiresrc videoconvert filesink; do
            gst-inspect-1.0 "$gst_element" >/dev/null 2>&1 \
                || die "Required GStreamer element is missing: $gst_element"
        done
    fi
else
    log "Installing Fedora build dependencies"

    sudo dnf install -y \
        git \
        git-lfs \
        gcc \
        gcc-c++ \
        make \
        cmake \
        meson \
        ninja-build \
        patch \
        pkgconf-pkg-config \
        python3-jinja2 \
        python3-ply \
        python3-pyyaml \
        libyaml-devel \
        openssl-devel \
        libevent-devel \
        elfutils-devel \
        elfutils-libelf-devel \
        libunwind-devel \
        systemd-devel \
        glib2-devel \
        libdrm-devel \
        libjpeg-turbo-devel \
        libtiff-devel \
        SDL2-devel \
        mesa-libEGL-devel \
        mesa-libGLES-devel \
        ncurses-devel \
        libX11-devel \
        libxcb-devel \
        libcap-devel \
        pciutils \
        mokutil \
        v4l-utils \
        gstreamer1 \
        gstreamer1-tools \
        gstreamer1-plugins-base
fi


if [[ ! -e "$KDIR/Makefile" ]] && \
   [[ "$BUILD_ONLY" -eq 0 ]] && \
   [[ "$KNOWN_GOOD_CONFIG" -eq 1 ]]
then
    log "Installing matching linux-surface development package"

    sudo dnf install -y \
        "kernel-surface-devel-$KVER" \
        || die "Matching kernel-surface-devel package could not be installed."
fi

[[ -e "$KDIR/Makefile" ]] \
    || die "Kernel build tree is missing: $KDIR. Install the headers/development package for the running kernel."

# -------------------------------------------------------------------------
# Secure Boot
# -------------------------------------------------------------------------

log "Checking Secure Boot"

SB_STATE="$(mokutil --sb-state 2>&1 || true)"
printf '%s\n' "$SB_STATE"

if grep -qi 'SecureBoot enabled' <<<"$SB_STATE"; then
    die "Secure Boot is enabled. v0.1 installs unsigned external modules."
fi

# -------------------------------------------------------------------------
# Source locations
# -------------------------------------------------------------------------

LINUX_REPO="$(repo_for_section Linux)"
IPU4_REPO="$(repo_for_section IPU4)"
LIBCAMERA_REPO="$(repo_for_section libcamera)"
PIPEWIRE_REPO="$(repo_for_section PipeWire)"
V4L2LOOPBACK_REPO="$(repo_for_section v4l2loopback)"

[[ -n "$LINUX_REPO" ]] || die "Linux repository missing from source-bases.txt"
[[ -n "$IPU4_REPO" ]] || die "IPU4 repository missing from source-bases.txt"
[[ -n "$LIBCAMERA_REPO" ]] || die "libcamera repository missing from source-bases.txt"
[[ -n "$PIPEWIRE_REPO" ]] || die "PipeWire repository missing from source-bases.txt"
[[ -n "$V4L2LOOPBACK_REPO" ]] || die "v4l2loopback repository missing from source-bases.txt"

FIRMWARE_REPO="${IPU4_REPO%georgemihaila/sp7-ipu4-camera.git}ruslanbay/ipu4-drivers.git"

[[ "$FIRMWARE_REPO" != "$IPU4_REPO" ]] \
    || die "Could not derive the firmware source repository."

WORK="$(mktemp -d -t sp7-camera-build.XXXXXXXX)"

BACKUP_ROOT="/var/lib/sp7-camera/backup-v0.1"

if [[ "$BUILD_ONLY" -eq 0 ]]; then
    sudo mkdir -p "$BACKUP_ROOT"
fi

printf '\nBuild directory: %s\n' "$WORK"

# -------------------------------------------------------------------------
# Kernel-side rear sensor, VCM and IPU bridge
# -------------------------------------------------------------------------

log "Building OV8865, DW9719 and IPU bridge"

LINUX_SRC="$WORK/linux"

fetch_ref_commit \
    "$LINUX_REPO" \
    "$LINUX_REF" \
    "$LINUX_COMMIT" \
    "$LINUX_SRC"

apply_patch \
    "$LINUX_SRC" \
    "$ROOT/patches/kernel/0001-sp7-ov8865-dw9719.patch"

apply_patch \
    "$LINUX_SRC" \
    "$ROOT/patches/kernel/0002-sp7-ipu-bridge-runtime-pm.patch"

KMOD_SRC="$WORK/kernel-modules"

mkdir -p "$KMOD_SRC"

cp \
    "$LINUX_SRC/drivers/media/i2c/ov8865.c" \
    "$KMOD_SRC/ov8865.c"

cp \
    "$LINUX_SRC/drivers/media/i2c/dw9719.c" \
    "$KMOD_SRC/dw9719.c"

cp \
    "$LINUX_SRC/drivers/media/pci/intel/ipu-bridge.c" \
    "$KMOD_SRC/ipu-bridge.c"

cat > "$KMOD_SRC/Makefile" <<'EOF'
obj-m += ov8865.o
obj-m += dw9719.o
obj-m += ipu-bridge.o
EOF

make \
    -C "$KDIR" \
    M="$KMOD_SRC" \
    -j"$(nproc)" \
    modules

for module in \
    "$KMOD_SRC/ov8865.ko" \
    "$KMOD_SRC/dw9719.ko" \
    "$KMOD_SRC/ipu-bridge.ko"
do
    [[ -f "$module" ]] \
        || die "Kernel module was not built: $module"

    check_vermagic "$module"
done

# -------------------------------------------------------------------------
# IPU4P stack
# -------------------------------------------------------------------------

log "Building patched IPU4P stack"

IPU4_SRC="$WORK/sp7-ipu4-camera"

fetch_commit \
    "$IPU4_REPO" \
    "$IPU4_COMMIT" \
    "$IPU4_SRC"

apply_patch \
    "$IPU4_SRC" \
    "$ROOT/patches/ipu4/0001-sp7-ipu4-isys.patch"

[[ -x "$IPU4_SRC/scripts/build-modules.sh" ]] \
    || die "IPU4 build script is missing."

(
    cd "$IPU4_SRC"

    KDIR="$KDIR" \
    KREL="$KVER" \
        ./scripts/build-modules.sh -j1
)

IPU4_MODULES=(
    intel-ipu4p.ko
    intel-ipu4p-isys.ko
    intel-ipu4p-psys.ko
    intel-ipu4p-isys-csslib.ko
    intel-ipu4p-psys-csslib.ko
)

declare -A IPU4_BUILT

for name in "${IPU4_MODULES[@]}"; do
    module="$(
        find "$IPU4_SRC" \
            -type f \
            -name "$name" \
            -print \
            -quit
    )"

    [[ -n "$module" && -f "$module" ]] \
        || die "Expected IPU4 module not found: $name"

    check_vermagic "$module"

    IPU4_BUILT["$name"]="$module"

    printf 'PASS: %s\n' "$module"
done

# -------------------------------------------------------------------------
# v4l2loopback 0.15.4 – upstream, unmodified
# -------------------------------------------------------------------------

log "Building upstream v4l2loopback 0.15.4"

V4L2_SRC="$WORK/v4l2loopback"

fetch_ref_commit \
    "$V4L2LOOPBACK_REPO" \
    "$V4L2LOOPBACK_REF" \
    "$V4L2LOOPBACK_COMMIT" \
    "$V4L2_SRC"

make \
    -C "$V4L2_SRC" \
    KERNELRELEASE="$KVER" \
    KERNEL_DIR="$KDIR" \
    -j"$(nproc)" \
    v4l2loopback.ko

[[ -f "$V4L2_SRC/v4l2loopback.ko" ]] \
    || die "v4l2loopback.ko was not built."

check_vermagic "$V4L2_SRC/v4l2loopback.ko"

V4L2_VERSION="$(modinfo -F version "$V4L2_SRC/v4l2loopback.ko" 2>/dev/null || true)"

[[ "$V4L2_VERSION" == "0.15.4" ]] \
    || die "Unexpected v4l2loopback version: $V4L2_VERSION"

if [[ "$BUILD_ONLY" -eq 0 ]]; then

# -------------------------------------------------------------------------
# Firmware
# -------------------------------------------------------------------------

log "Installing verified IPU4P firmware"

FW_SOURCE="${FIRMWARE:-}"

if [[ -z "$FW_SOURCE" ]] &&
   [[ -f /usr/lib/firmware/ipu4p_cpd.bin ]] &&
   echo "$FIRMWARE_SHA256  /usr/lib/firmware/ipu4p_cpd.bin" | sha256sum -c - >/dev/null 2>&1
then
    echo "Correct firmware is already installed."
else
    if [[ -z "$FW_SOURCE" ]]; then
        FW_SRC="$WORK/ipu4-drivers"

        export GIT_LFS_SKIP_SMUDGE=1

        fetch_commit \
            "$FIRMWARE_REPO" \
            "$FIRMWARE_COMMIT" \
            "$FW_SRC"

        unset GIT_LFS_SKIP_SMUDGE

        git -C "$FW_SRC" lfs pull \
            --include="firmware/ipu4-20191030.bin"

        FW_SOURCE="$FW_SRC/firmware/ipu4-20191030.bin"
    fi

    [[ -f "$FW_SOURCE" ]] \
        || die "Firmware file not found: $FW_SOURCE"

    echo "$FIRMWARE_SHA256  $FW_SOURCE" \
        | sha256sum -c -

    backup_system_file /usr/lib/firmware/ipu4p_cpd.bin

    sudo install \
        -D \
        -m 0644 \
        "$FW_SOURCE" \
        /usr/lib/firmware/ipu4p_cpd.bin
fi

# -------------------------------------------------------------------------
# Install kernel modules
# -------------------------------------------------------------------------

log "Installing kernel modules"

sudo mkdir -p "$MODULE_DEST"

for module in \
    "$KMOD_SRC/ov8865.ko" \
    "$KMOD_SRC/dw9719.ko" \
    "$KMOD_SRC/ipu-bridge.ko"
do
    name="$(basename "$module")"

    backup_system_file "$MODULE_DEST/$name"

    sudo install \
        -m 0644 \
        "$module" \
        "$MODULE_DEST/$name"
done

for name in "${IPU4_MODULES[@]}"; do
    module="${IPU4_BUILT[$name]}"

    backup_system_file "$MODULE_DEST/$name"

    sudo install \
        -m 0644 \
        "$module" \
        "$MODULE_DEST/$name"
done

backup_system_file "$MODULE_DEST/v4l2loopback.ko"

sudo install \
    -m 0644 \
    "$V4L2_SRC/v4l2loopback.ko" \
    "$MODULE_DEST/v4l2loopback.ko"

sudo depmod -a "$KVER"

fi

# -------------------------------------------------------------------------
# libcamera 0.7.2
# -------------------------------------------------------------------------

log "Building and installing patched libcamera"

LIBCAMERA_SRC="$WORK/libcamera"
LIBCAMERA_BUILD="$WORK/libcamera-build"

fetch_commit \
    "$LIBCAMERA_REPO" \
    "$LIBCAMERA_COMMIT" \
    "$LIBCAMERA_SRC"

apply_patch \
    "$LIBCAMERA_SRC" \
    "$ROOT/patches/libcamera/0001-sp7-camera.patch"

[[ -f "$LIBCAMERA_SRC/src/ipa/simple/data/ov8865.yaml" ]] \
    || die "OV8865 tuning file is missing from the libcamera patch."

meson setup \
    "$LIBCAMERA_BUILD" \
    "$LIBCAMERA_SRC" \
    --prefix=/usr/local \
    --libdir=lib64 \
    --buildtype=debugoptimized \
    -Dcam=enabled \
    -Dqcam=disabled \
    -Ddocumentation=disabled \
    -Dtest=false \
    -Dpipelines=simple

ninja \
    -C "$LIBCAMERA_BUILD" \
    -j"$(nproc)"

STAGE="$WORK/stage"

if [[ "$BUILD_ONLY" -eq 1 ]]; then
    log "Staging patched libcamera for build-only verification"

    mkdir -p "$STAGE"

    DESTDIR="$STAGE" meson install \
        -C "$LIBCAMERA_BUILD"

    install \
        -D \
        -m 0644 \
        "$LIBCAMERA_SRC/src/ipa/simple/data/ov8865.yaml" \
        "$STAGE/usr/local/share/libcamera/ipa/simple/ov8865.yaml"

    [[ -e "$STAGE/usr/local/lib64/libcamera.so.0.7" ]] \
        || die "Staged libcamera.so.0.7 is missing."

    [[ -e "$STAGE/usr/local/lib64/libcamera-base.so.0.7" ]] \
        || die "Staged libcamera-base.so.0.7 is missing."

    [[ -e "$STAGE/usr/local/lib64/libcamera/ipa/ipa_soft_simple.so" ]] \
        || die "Staged SoftISP IPA is missing."

    [[ -e "$STAGE/usr/local/share/libcamera/ipa/simple/ov8865.yaml" ]] \
        || die "Staged OV8865 tuning file is missing."
else
    sudo meson install \
        -C "$LIBCAMERA_BUILD"

    # The custom OV8865 tuning file is part of our patch, but the upstream
    # simple-pipeline Meson install list does not install this new file.
    sudo install \
        -D \
        -m 0644 \
        "$LIBCAMERA_SRC/src/ipa/simple/data/ov8865.yaml" \
        /usr/local/share/libcamera/ipa/simple/ov8865.yaml

    printf '%s\n' '/usr/local/lib64' \
        | sudo tee /etc/ld.so.conf.d/sp7-camera.conf >/dev/null

    sudo ldconfig

    [[ -e /usr/local/lib64/libcamera.so.0.7 ]] \
        || die "Custom libcamera was not installed."

    [[ -e /usr/local/lib64/libcamera-base.so.0.7 ]] \
        || die "Custom libcamera-base was not installed."

    [[ -e /usr/local/lib64/libcamera/ipa/ipa_soft_simple.so ]] \
        || die "SoftISP IPA was not installed."

fi

# -------------------------------------------------------------------------
# PipeWire libcamera SPA only
# -------------------------------------------------------------------------

log "Building patched PipeWire libcamera SPA"

PIPEWIRE_SRC="$WORK/pipewire"
PIPEWIRE_BUILD="$WORK/pipewire-build"
PIPEWIRE_PREFIX="$WORK/pipewire-prefix"

fetch_commit \
    "$PIPEWIRE_REPO" \
    "$PIPEWIRE_COMMIT" \
    "$PIPEWIRE_SRC"

apply_patch \
    "$PIPEWIRE_SRC" \
    "$ROOT/patches/pipewire/0001-sp7-libcamera-profiles.patch"

SP7_ORIGINAL_PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"

if [[ "$BUILD_ONLY" -eq 1 ]]; then
    # DESTDIR preserves prefix=/usr/local in libcamera's .pc files.
    # Rewrite only the staged libcamera metadata instead of applying a
    # global PKG_CONFIG_SYSROOT_DIR, which would also redirect Fedora
    # dependencies such as glib-2.0 into the temporary stage.
    for pc in \
        "$STAGE/usr/local/lib64/pkgconfig/libcamera.pc" \
        "$STAGE/usr/local/lib64/pkgconfig/libcamera-base.pc"
    do
        [[ -f "$pc" ]] \
            || die "Staged pkg-config file is missing: $pc"

        sed -i \
            "s|^prefix=/usr/local\$|prefix=$STAGE/usr/local|" \
            "$pc"

        grep -Fx \
            "prefix=$STAGE/usr/local" \
            "$pc" >/dev/null \
            || die "Could not redirect staged pkg-config file: $pc"
    done

    export PKG_CONFIG_PATH="$STAGE/usr/local/lib64/pkgconfig${SP7_ORIGINAL_PKG_CONFIG_PATH:+:$SP7_ORIGINAL_PKG_CONFIG_PATH}"
    unset PKG_CONFIG_SYSROOT_DIR
else
    export PKG_CONFIG_PATH="/usr/local/lib64/pkgconfig${SP7_ORIGINAL_PKG_CONFIG_PATH:+:$SP7_ORIGINAL_PKG_CONFIG_PATH}"
    unset PKG_CONFIG_SYSROOT_DIR
fi

meson setup \
    "$PIPEWIRE_BUILD" \
    "$PIPEWIRE_SRC" \
    --prefix="$PIPEWIRE_PREFIX" \
    --libdir=lib64 \
    --buildtype=debugoptimized \
    -Dlibcamera=enabled \
    -Ddbus=disabled \
    -Dsystemd=disabled \
    -Dselinux=disabled \
    -Dgstreamer=disabled \
    -Dgstreamer-device-provider=disabled \
    -Dalsa=disabled \
    -Dbluez5=disabled \
    -Djack=disabled \
    -Dv4l2=disabled \
    -Dudev=disabled \
    -Dsdl2=disabled \
    -Dtests=disabled \
    -Dexamples=disabled \
    -Dman=disabled \
    -Ddocs=disabled \
    -Dsession-managers=[]

ninja \
    -C "$PIPEWIRE_BUILD" \
    -j"$(nproc)" \
    spa/plugins/libcamera/libspa-libcamera.so

SPA="$PIPEWIRE_BUILD/spa/plugins/libcamera/libspa-libcamera.so"

[[ -f "$SPA" ]] \
    || die "PipeWire libcamera SPA was not built."


if [[ "$BUILD_ONLY" -eq 1 ]]; then
    log "Verifying PipeWire SPA against staged libcamera"

    if ! LD_LIBRARY_PATH="$STAGE/usr/local/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        ldd "$SPA" \
        | grep -F "$STAGE/usr/local/lib64/libcamera.so.0.7" >/dev/null
    then
        die "PipeWire SPA does not resolve staged libcamera.so.0.7."
    fi
else

    sudo install \
        -D \
        -m 0755 \
        "$SPA" \
        /usr/local/lib64/spa-0.2/libcamera/libspa-libcamera.so

    sudo ldconfig

    ldd /usr/local/lib64/spa-0.2/libcamera/libspa-libcamera.so \
        | grep -F '/usr/local/lib64/libcamera.so.0.7' >/dev/null \
        || die "Installed SPA does not resolve custom libcamera from /usr/local."

fi

# -------------------------------------------------------------------------
# V4L2 compatibility helpers
# -------------------------------------------------------------------------

log "Building SP7 V4L2 compatibility helpers"

cc \
    -O2 \
    -Wall \
    -Wextra \
    -o "$WORK/sp7-camera-relay" \
    "$ROOT/src/sp7-camera-relay.c"

cc \
    -O2 \
    -Wall \
    -Wextra \
    -o "$WORK/sp7-camera-client-usage" \
    "$ROOT/src/sp7-camera-client-usage.c"

if [[ "$BUILD_ONLY" -eq 1 ]]; then
    log "BUILD-ONLY SUCCESS"

    echo
    echo "Kernel modules:"
    for module in \
        "$KMOD_SRC/ov8865.ko" \
        "$KMOD_SRC/dw9719.ko" \
        "$KMOD_SRC/ipu-bridge.ko" \
        "$V4L2_SRC/v4l2loopback.ko"
    do
        sha256sum "$module"
        modinfo -F vermagic "$module"
    done

    echo
    echo "IPU4 modules:"
    for name in "${IPU4_MODULES[@]}"; do
        sha256sum "${IPU4_BUILT[$name]}"
        modinfo -F vermagic "${IPU4_BUILT[$name]}"
    done

    echo
    echo "Staged libcamera:"
    sha256sum \
        "$STAGE/usr/local/lib64/libcamera.so.0.7" \
        "$STAGE/usr/local/lib64/libcamera-base.so.0.7" \
        "$STAGE/usr/local/lib64/libcamera/ipa/ipa_soft_simple.so" \
        "$STAGE/usr/local/share/libcamera/ipa/simple/ov8865.yaml"

    echo
    echo "PipeWire SPA:"
    sha256sum "$SPA"

    echo
    echo "PipeWire SPA dependencies:"
    LD_LIBRARY_PATH="$STAGE/usr/local/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        ldd "$SPA" \
        | grep -E 'libcamera|libcamera-base'

    echo
    echo "V4L2 helper binaries:"
    sha256sum \
        "$WORK/sp7-camera-relay" \
        "$WORK/sp7-camera-client-usage"

    echo
    echo "============================================================"
    echo " BUILD-ONLY COMPLETE"
    echo
    echo " All release sources were fetched from their pinned commits."
    echo " All release patches applied."
    echo " Kernel modules built successfully."
    echo " libcamera built and staged successfully."
    echo " PipeWire libcamera SPA built against the staged libcamera."
    echo " V4L2 helper binaries built successfully."
    echo
    echo " No kernel modules, firmware, libraries, services or"
    echo " configuration files were installed by --build-only."
    echo "============================================================"

    exit 0
fi

sudo install \
    -D \
    -m 0755 \
    "$WORK/sp7-camera-relay" \
    /usr/local/libexec/sp7-camera-relay

sudo install \
    -D \
    -m 0755 \
    "$WORK/sp7-camera-client-usage" \
    /usr/local/libexec/sp7-camera-client-usage

sudo install \
    -D \
    -m 0755 \
    "$ROOT/src/sp7-camera-controller" \
    /usr/local/libexec/sp7-camera-controller

sudo install \
    -D \
    -m 0755 \
    "$ROOT/scripts/sp7-wait-dw9719" \
    /usr/local/libexec/sp7-wait-dw9719

sudo install \
    -D \
    -m 0755 \
    "$ROOT/scripts/sp7-camera-boot" \
    /usr/local/sbin/sp7-camera-boot

for profile in standard hq fast front-standard front-hq; do
    sudo install \
        -D \
        -m 0644 \
        "$ROOT/config/profiles/$profile.env" \
        "/usr/local/share/sp7-camera/$profile.env"
done

# -------------------------------------------------------------------------
# System configuration
# -------------------------------------------------------------------------

log "Installing system configuration"

install_system_file \
    "$ROOT/config/modprobe.d/ipu4p.conf" \
    /etc/modprobe.d/ipu4p.conf \
    0644

install_system_file \
    "$ROOT/config/modprobe.d/sp7-v4l2loopback.conf" \
    /etc/modprobe.d/sp7-v4l2loopback.conf \
    0644

install_system_file \
    "$ROOT/config/modules-load.d/sp7-v4l2loopback.conf" \
    /etc/modules-load.d/sp7-v4l2loopback.conf \
    0644

install_system_file \
    "$ROOT/systemd/system/sp7-camera-boot.service" \
    /etc/systemd/system/sp7-camera-boot.service \
    0644

sudo systemctl daemon-reload
sudo systemctl enable sp7-camera-boot.service

# -------------------------------------------------------------------------
# Per-user WirePlumber and controller configuration
# -------------------------------------------------------------------------

log "Installing desktop-user configuration"

WP_DIR="$HOME/.config/wireplumber/wireplumber.conf.d"
USER_SYSTEMD="$HOME/.config/systemd/user"
USER_DROPIN="$USER_SYSTEMD/wireplumber.service.d"

mkdir -p \
    "$WP_DIR" \
    "$USER_SYSTEMD" \
    "$USER_DROPIN"

install \
    -m 0644 \
    "$ROOT/config/wireplumber/wireplumber.conf.d/99-sp7-three-rear-names.conf" \
    "$WP_DIR/99-sp7-three-rear-names.conf"

# Keep the ALC274 hardware mixer at the known-good microphone gain.
# WirePlumber still controls source/sink volume in software.
install \
    -m 0644 \
    "$ROOT/config/wireplumber/wireplumber.conf.d/99-sp7-audio-soft-mixer.conf" \
    "$WP_DIR/99-sp7-audio-soft-mixer.conf"

for file in \
    90-sp7-libcamera-test.conf \
    95-sp7-softisp-vflip.conf \
    96-sp7-wait-dw9719.conf \
    97-sp7-camera-mode.conf
do
    install \
        -m 0644 \
        "$ROOT/systemd/user/wireplumber.service.d/$file" \
        "$USER_DROPIN/$file"
done

install \
    -m 0644 \
    "$ROOT/systemd/user/sp7-camera-controller.service" \
    "$USER_SYSTEMD/sp7-camera-controller.service"

install \
    -m 0644 \
    "$ROOT/systemd/user/sp7-camera-relay@.service" \
    "$USER_SYSTEMD/sp7-camera-relay@.service"

systemctl --user daemon-reload
systemctl --user enable sp7-camera-controller.service

# Surface Pro 7 ALC274 internal microphone gain fix.
# The helper sets the known-good hardware boost to 0 dB.
# The WirePlumber soft-mixer rule above prevents later PipeWire volume
# restoration from raising this hardware control back to +30 dB.
# The helper is non-fatal if the expected ALSA card/control is absent.
sudo install -Dm755 \
    "$ROOT/src/sp7-audio-fix" \
    /usr/local/libexec/sp7-audio-fix

install -Dm644 \
    "$ROOT/systemd/user/sp7-audio-fix.service" \
    "$USER_SYSTEMD/sp7-audio-fix.service"

systemctl --user daemon-reload
systemctl --user enable sp7-audio-fix.service

# WirePlumber reads static configuration fragments only at startup.
# Restart it so the ALC274 soft-mixer rule takes effect immediately.
systemctl --user restart wireplumber.service

# Establish the known-good hardware mixer value after WirePlumber has
# restarted. This is also required when updating an existing installation
# where the oneshot service may already be active.
systemctl --user restart sp7-audio-fix.service

# -------------------------------------------------------------------------
# Final static verification
# -------------------------------------------------------------------------

log "Final installation verification"

echo
echo "Kernel modules:"
for module in \
    ov8865 \
    dw9719 \
    ipu_bridge \
    intel_ipu4p \
    intel_ipu4p_isys \
    intel_ipu4p_psys \
    intel_ipu4p_isys_csslib \
    intel_ipu4p_psys_csslib \
    v4l2loopback
do
    path="$(modinfo -n "$module" 2>/dev/null || true)"
    printf '%-28s %s\n' "$module" "$path"

    [[ -n "$path" ]] \
        || die "Installed module cannot be resolved: $module"
done

echo
echo "Firmware:"
sha256sum /usr/lib/firmware/ipu4p_cpd.bin

echo
echo "Custom libcamera:"
ls -l \
    /usr/local/lib64/libcamera.so.0.7 \
    /usr/local/lib64/libcamera-base.so.0.7 \
    /usr/local/lib64/libcamera/ipa/ipa_soft_simple.so \
    /usr/local/share/libcamera/ipa/simple/ov8865.yaml

echo
echo "PipeWire SPA:"
ls -l /usr/local/lib64/spa-0.2/libcamera/libspa-libcamera.so

echo
echo "User services:"
systemctl --user is-enabled sp7-camera-controller.service || true

echo
echo "System service:"
systemctl is-enabled sp7-camera-boot.service || true

cat <<'EOF'

============================================================
 INSTALLATION COMPLETE
============================================================

The camera stack has been installed for the current Surface Pro 7 system.
Fedora Workstation 43 with kernel 6.19.8-3.surface.fc43.x86_64 is the
known-good configuration; installations made with --allow-untested-distro
are experimental.

No camera modules have deliberately been reloaded into the current session.

Reboot the Surface Pro 7 before using the camera.

After reboot:
  - GNOME Snapshot should expose Rear Standard and Rear HQ.
  - V4L2 applications should expose Rear Standard, Rear HQ and Rear Fast.
  - Only one physical rear-camera stream can own the sensor at a time.

Known v0.1 limitations:
  - Snapshot and V4L2 applications must not use the physical camera concurrently.
  - Autofocus convergence is relatively slow.
  - Auto-exposure convergence is relatively slow.
  - Rear Fast can show a green cast in low light.
  - Signal may mirror its local self-preview.

============================================================
EOF
