#!/bin/bash
# SPDX-FileCopyrightText: 2026 Christian Semmelmann
# SPDX-License-Identifier: Apache-2.0

# Runs a development build of apple/container with container-runtime-macos.
#
# The development build lives in its own checkout, its own application data root and its
# own log root. The installed container stays untouched: its binaries, data and containers
# remain as they are. Both builds register the same launchd service, so only one runs at a
# time: `up` stops the installed services and `down` starts them again.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANAGED_SRC="${PLUGIN_ROOT}/.build/dev-env/container"
CONTAINER_SRC="${CONTAINER_SRC:-${MANAGED_SRC}}"
DEV_APP_ROOT="${DEV_APP_ROOT:-${HOME}/.container-macos-dev}"
DEV_LOG_ROOT="${DEV_LOG_ROOT:-${DEV_APP_ROOT}/logs}"
INSTALLED="${INSTALLED_CONTAINER:-/usr/local/bin/container}"
DEV="${CONTAINER_SRC}/bin/container"
STATE_FILE="${DEV_APP_ROOT}/.installed-was-running"
APISERVER_LABEL="com.apple.container.apiserver"

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [arguments]

Commands:
  build                 Build container and the plugin into ${CONTAINER_SRC}
  up [--no-build] [-y]  Stop the installed services and start the development services
  down                  Stop the development services and restart the installed ones
  status                Show which container services run
  run BUNDLE [ARGS...]  Run a macOS container from BUNDLE; ARGS go to 'container run'
  logs                  Follow the runtime plugin logs
  container ARGS...     Run the development CLI

Environment:
  CONTAINER_SRC          apple/container checkout (default: .build/dev-env/container, a clone of
                         the container revision in Package.resolved that build creates)
  DEV_APP_ROOT           Application data of the development build (default: ~/.container-macos-dev)
  INSTALLED_CONTAINER    Installed CLI (default: /usr/local/bin/container)
EOF
}

step() { printf '==> %s\n' "$*"; }
fail() {
    echo "error: $*" >&2
    exit 1
}

# Prints the apiserver binary that launchd runs, or nothing when none runs.
running_apiserver() {
    launchctl print "gui/$(id -u)/${APISERVER_LABEL}" 2>/dev/null | awk '/^[[:space:]]*program = / { print $3; exit }'
}

dev_running() { [[ "$(running_apiserver)" == "${CONTAINER_SRC}/bin/container-apiserver" ]]; }

# Prints a field (location or revision) of the container pin in Package.resolved.
container_pin() {
    awk -v field="\"$1\"" '
        $1 == "\"identity\"" { pin = ($3 == "\"container\",") }
        pin && $1 == field { gsub(/[",]/, "", $3); print $3; exit }
    ' "${PLUGIN_ROOT}/Package.resolved"
}

# Clones the pinned container package into MANAGED_SRC and checks out its pinned revision.
# A CONTAINER_SRC override is used as it is.
sync_source() {
    [[ "${CONTAINER_SRC}" == "${MANAGED_SRC}" ]] || return 0
    local location revision
    location="$(container_pin location)"
    revision="$(container_pin revision)"
    [[ -n "${location}" && -n "${revision}" ]] || fail "Package.resolved pins no container package; run 'swift package resolve'"
    if [[ ! -d "${MANAGED_SRC}/.git" ]]; then
        step "Cloning ${location} into ${MANAGED_SRC}"
        mkdir -p "$(dirname "${MANAGED_SRC}")"
        git clone -q --no-checkout "${location}" "${MANAGED_SRC}"
    fi
    [[ "$(git -C "${MANAGED_SRC}" rev-parse HEAD 2>/dev/null)" == "${revision}" ]] && return 0
    step "Checking out container ${revision}"
    git -C "${MANAGED_SRC}" cat-file -e "${revision}^{commit}" 2>/dev/null || git -C "${MANAGED_SRC}" fetch -q origin "${revision}"
    git -C "${MANAGED_SRC}" -c advice.detachedHead=false checkout -q --detach "${revision}"
}

build() {
    sync_source
    step "Building container in ${CONTAINER_SRC}"
    make -C "${CONTAINER_SRC}" container
    step "Installing the plugin into ${CONTAINER_SRC}/libexec/container-plugins"
    ocx --project "${PLUGIN_ROOT}" exec -- task -d "${PLUGIN_ROOT}" install INSTALL_ROOT="${CONTAINER_SRC}"
}

up() {
    local do_build=1 assume_yes=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-build)
                do_build=0
                shift
                ;;
            -y | --yes)
                assume_yes=1
                shift
                ;;
            *) fail "unknown option: $1" ;;
        esac
    done

    dev_running && fail "the development services already run"
    [[ "${do_build}" == 1 ]] && build
    [[ -x "${DEV}" ]] || fail "${DEV} not found; run '$(basename "$0") build'"

    mkdir -p "${DEV_APP_ROOT}" "${DEV_LOG_ROOT}"
    rm -f "${STATE_FILE}"

    if [[ -n "$(running_apiserver)" ]]; then
        local running
        running="$("${INSTALLED}" list --quiet 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "${running}" != 0 && "${assume_yes}" != 1 ]]; then
            read -r -p "Stopping the installed services stops ${running} running container(s). Continue? [y/N] " answer
            [[ "${answer}" == [yY] ]] || fail "aborted"
        fi
        step "Stopping the installed container services"
        "${INSTALLED}" system stop
        touch "${STATE_FILE}"
    fi

    step "Starting the development services (data: ${DEV_APP_ROOT})"
    "${DEV}" system start \
        --app-root "${DEV_APP_ROOT}" \
        --install-root "${CONTAINER_SRC}" \
        --log-root "${DEV_LOG_ROOT}" \
        --disable-kernel-install
    step "Development services run; '$(basename "$0") down' restores the installed ones"
}

down() {
    if dev_running; then
        step "Stopping the development services"
        "${DEV}" system stop
    fi
    if [[ -f "${STATE_FILE}" ]]; then
        step "Starting the installed container services"
        "${INSTALLED}" system start
        rm -f "${STATE_FILE}"
    fi
}

status() {
    local program
    program="$(running_apiserver)"
    if [[ -z "${program}" ]]; then
        echo "no container services run"
    elif dev_running; then
        echo "development services run (${program}, data: ${DEV_APP_ROOT})"
    else
        echo "installed services run (${program})"
    fi
}

run() {
    [[ $# -ge 1 ]] || fail "usage: $(basename "$0") run BUNDLE [ARGS...]"
    local bundle
    bundle="$(cd "$1" && pwd)"
    shift
    dev_running || fail "the development services do not run; start them with '$(basename "$0") up'"
    "${DEV}" run -d \
        --runtime container-runtime-macos \
        --label "runtime-macos.bundle=${bundle}" \
        --cpus 4 --memory 8G \
        "$@" \
        alpine
}

logs() {
    tail -F "${DEV_LOG_ROOT}"/container-runtime-macos-*.log
}

command="${1:-}"
[[ -n "${command}" ]] || {
    usage
    exit 2
}
shift
case "${command}" in
    build) build ;;
    up) up "$@" ;;
    down) down ;;
    status) status ;;
    run) run "$@" ;;
    logs) logs ;;
    container)
        dev_running || fail "the development services do not run"
        "${DEV}" "$@"
        ;;
    -h | --help | help) usage ;;
    *)
        usage >&2
        exit 2
        ;;
esac
