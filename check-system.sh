#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later

set +e

EXPECTED_OS="fedora"
EXPECTED_VERSION="43"
EXPECTED_ARCH="x86_64"
EXPECTED_KERNEL="6.19.8-3.surface.fc43.x86_64"

ALLOW_UNTESTED_DISTRO=0

for arg in "$@"; do
    case "$arg" in
        --allow-untested-distro)
            ALLOW_UNTESTED_DISTRO=1
            ;;
        -h|--help)
            printf 'Usage: %s [--allow-untested-distro]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Usage: %s [--allow-untested-distro]\n' "$0" >&2
            exit 2
            ;;
    esac
done

PASS=0
WARN=0
FAIL=0

ok()
{
    printf 'PASS  %s\n' "$*"
    PASS=$((PASS + 1))
}

warn()
{
    printf 'WARN  %s\n' "$*"
    WARN=$((WARN + 1))
}

fail()
{
    printf 'FAIL  %s\n' "$*"
    FAIL=$((FAIL + 1))
}

echo "============================================================"
echo " Surface Pro 7 Camera – System Check"
echo "============================================================"
echo

# ------------------------------------------------------------
# Device
# ------------------------------------------------------------

PRODUCT="$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
echo "Device:       ${PRODUCT:-unknown}"

case "$PRODUCT" in
    *"Surface Pro 7+"*)
        fail "Surface Pro 7+ is not supported by this project"
        ;;
    *"Surface Pro 7"*)
        ok "Surface Pro 7 detected"
        ;;
    *)
        fail "This release is validated only on Microsoft Surface Pro 7"
        ;;
esac

# ------------------------------------------------------------
# Distribution
# ------------------------------------------------------------

if [ -r /etc/os-release ]; then
    . /etc/os-release
else
    ID=""
    VERSION_ID=""
fi

echo "Distribution: ${PRETTY_NAME:-unknown}"

if [ "$ID" = "$EXPECTED_OS" ] && [ "$VERSION_ID" = "$EXPECTED_VERSION" ]; then
    ok "Known-good distribution: Fedora 43"
elif [ "$ALLOW_UNTESTED_DISTRO" -eq 1 ]; then
    warn "Untested distribution accepted for experimental testing: ${PRETTY_NAME:-unknown}"
else
    fail "Untested distribution: ${PRETTY_NAME:-unknown} (use --allow-untested-distro for deliberate experimental testing)"
fi

# ------------------------------------------------------------
# Architecture
# ------------------------------------------------------------

ARCH="$(uname -m)"
echo "Architecture: $ARCH"

if [ "$ARCH" = "$EXPECTED_ARCH" ]; then
    ok "x86_64 architecture"
else
    fail "Expected x86_64"
fi

# ------------------------------------------------------------
# Kernel
# ------------------------------------------------------------

KERNEL="$(uname -r)"
echo "Kernel:       $KERNEL"

if [ "$KERNEL" = "$EXPECTED_KERNEL" ]; then
    ok "Validated linux-surface kernel detected"
elif [ "$ALLOW_UNTESTED_DISTRO" -eq 1 ]; then
    warn "Untested kernel accepted for experimental testing: $KERNEL"
else
    fail "Expected kernel $EXPECTED_KERNEL (use --allow-untested-distro for deliberate experimental testing)"
fi

# ------------------------------------------------------------
# Kernel build tree
# ------------------------------------------------------------

if [ -f "/lib/modules/$KERNEL/build/Makefile" ]; then
    ok "Matching kernel build tree is installed"
else
    fail "Missing kernel build tree: /lib/modules/$KERNEL/build"
fi

# ------------------------------------------------------------
# Secure Boot
# ------------------------------------------------------------

if command -v mokutil >/dev/null 2>&1; then
    SB="$(mokutil --sb-state 2>/dev/null)"

    case "$SB" in
        *disabled*|*Disabled*)
            ok "Secure Boot is disabled"
            ;;
        *enabled*|*Enabled*)
            fail "Secure Boot is enabled; locally built unsigned modules will not load"
            ;;
        *)
            warn "Could not determine Secure Boot state: $SB"
            ;;
    esac
else
    warn "mokutil is not installed; Secure Boot state not checked"
fi

# ------------------------------------------------------------
# Required hardware
# ------------------------------------------------------------

if lspci -nn 2>/dev/null | grep -qi '8086:8a19'; then
    ok "Intel IPU4P PCI device 8086:8a19 detected"
else
    fail "Intel IPU4P PCI device 8086:8a19 not detected"
fi

# ------------------------------------------------------------
# Build/runtime tools
# ------------------------------------------------------------

echo
echo "Tools:"

for cmd in \
    git \
    gcc \
    g++ \
    make \
    meson \
    ninja \
    pkg-config \
    python3 \
    patch \
    sha256sum \
    gst-launch-1.0 \
    v4l2-ctl \
    pw-cli \
    systemctl
do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd"
    else
        warn "$cmd is not installed"
    fi
done

# ------------------------------------------------------------
# Existing firmware
# ------------------------------------------------------------

echo
echo "Firmware:"

FW="/usr/lib/firmware/ipu4p_cpd.bin"
EXPECTED_FW_SHA="ff2c36cc81a5c726508b22970c2e2538ff06107dc5a72c93401403c227e5157f"

if [ -f "$FW" ]; then
    FW_SHA="$(sha256sum "$FW" | awk '{print $1}')"

    if [ "$FW_SHA" = "$EXPECTED_FW_SHA" ]; then
        ok "Known-good IPU4P firmware detected"
    else
        warn "IPU4P firmware exists but has a different SHA256"
        echo "      Found:    $FW_SHA"
        echo "      Expected: $EXPECTED_FW_SHA"
    fi
else
    warn "IPU4P firmware is not installed yet"
fi

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Results"
echo "============================================================"
echo "PASS: $PASS"
echo "WARN: $WARN"
echo "FAIL: $FAIL"
echo

if [ "$FAIL" -eq 0 ]; then
    if [ "${ID:-}" = "$EXPECTED_OS" ] &&
       [ "${VERSION_ID:-}" = "$EXPECTED_VERSION" ] &&
       [ "$KERNEL" = "$EXPECTED_KERNEL" ]
    then
        echo "SUPPORTED: This is the known-good v0.1 configuration."
    else
        echo "EXPERIMENTAL: Mandatory safety checks passed, but this"
        echo "configuration has not been validated by the project."
    fi
    RC=0
else
    echo "UNSUPPORTED: Do not install the v0.1 camera stack on this system."
    RC=1
fi

echo
echo "No system settings were changed."
echo "============================================================"

if [ "$RC" -eq 0 ]; then
    true
else
    false
fi
