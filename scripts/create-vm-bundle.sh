#!/bin/bash
# SPDX-FileCopyrightText: 2026 Christian Semmelmann
# SPDX-License-Identifier: Apache-2.0

# Creates a macOS VM bundle for container-runtime-macos:
# downloads the latest supported restore image, installs macOS into a new bundle,
# and boots the bundle in a window for the Setup Assistant.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="${HOME}/VM.bundle"
IPSW=""
CACHE_DIR="${HOME}/Library/Caches/container-runtime-macos"
DISK_SIZE=100
CPUS=4
MEMORY=8
RUN_SETUP=1

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Creates a macOS VM bundle that container-runtime-macos boots.

Options:
  --bundle PATH      Bundle to create (default: ${BUNDLE})
  --ipsw PATH        Restore image to install; skips the download
  --cache-dir PATH   Download directory for restore images (default: ${CACHE_DIR})
  --disk-size GIB    Size of the sparse disk image (default: ${DISK_SIZE})
  --cpus N           CPUs for installation and setup (default: ${CPUS})
  --memory GIB       Memory for installation and setup (default: ${MEMORY})
  --no-setup         Skip the Setup Assistant window
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle)
            BUNDLE="$2"
            shift 2
            ;;
        --ipsw)
            IPSW="$2"
            shift 2
            ;;
        --cache-dir)
            CACHE_DIR="$2"
            shift 2
            ;;
        --disk-size)
            DISK_SIZE="$2"
            shift 2
            ;;
        --cpus)
            CPUS="$2"
            shift 2
            ;;
        --memory)
            MEMORY="$2"
            shift 2
            ;;
        --no-setup)
            RUN_SETUP=0
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

step() { printf '\n==> %s\n' "$*"; }
fail() {
    echo "error: $*" >&2
    exit 1
}

[[ "$(uname -m)" == "arm64" ]] || fail "macOS guests need a Mac with Apple silicon"
[[ -e "${BUNDLE}" ]] && fail "${BUNDLE} already exists; remove it or pass --bundle"

step "Building and signing parbake"
ocx --project "${PLUGIN_ROOT}" exec -- task -d "${PLUGIN_ROOT}" sign >/dev/null
PARBAKE="$(ocx --project "${PLUGIN_ROOT}" exec -- task -d "${PLUGIN_ROOT}" bin-path)/parbake"

if [[ -z "${IPSW}" ]]; then
    step "Looking up the latest supported restore image"
    URL="$("${PARBAKE}" ipsw-url)"
    IPSW="${CACHE_DIR}/$(basename "${URL}")"
    mkdir -p "${CACHE_DIR}"
    if [[ -f "${IPSW}.done" ]]; then
        echo "Using cached ${IPSW}"
    else
        step "Downloading ${URL##*/} (resumes an interrupted download)"
        curl --fail --location --continue-at - --output "${IPSW}" "${URL}"
        touch "${IPSW}.done"
    fi
fi
[[ -f "${IPSW}" ]] || fail "restore image ${IPSW} not found"

step "Installing macOS into ${BUNDLE}"
"${PARBAKE}" install --bundle "${BUNDLE}" --ipsw "${IPSW}" \
    --disk-size "${DISK_SIZE}" --cpus "${CPUS}" --memory "${MEMORY}"

if [[ "${RUN_SETUP}" == 1 ]]; then
    step "Opening the guest for the Setup Assistant"
    cat <<EOF
In the window:
  1. Complete the Setup Assistant and create the user account.
  2. Optional: System Settings > General > Sharing > Remote Login, for SSH access.
  3. Shut down the guest from its Apple menu; the window closes and this script continues.
EOF
    "${PARBAKE}" setup --bundle "${BUNDLE}" --cpus "${CPUS}" --memory "${MEMORY}"
fi

step "Done"
cat <<EOF
Bundle: ${BUNDLE}
Boot it with the development services:
  ${PLUGIN_ROOT}/scripts/dev-env.sh up
  ${PLUGIN_ROOT}/scripts/dev-env.sh run ${BUNDLE}
EOF
