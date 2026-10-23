#!/bin/bash
# SPDX-FileCopyrightText: 2026 Christian Semmelmann
# SPDX-License-Identifier: Apache-2.0

# Checks the module boundaries and the process hardening rules of the Swift sources.
#
# Usage: lint-boundaries.sh [--self-test] [ROOT]
#
# Rules, checked under ROOT/Sources:
#   - `import AppKit` appears only in Sources/parbake/Setup.swift.
#   - Sources/parbake-agent/ imports neither RuntimeMacOS nor Virtualization.
#   - Each entry point calls `signal(SIGPIPE, SIG_IGN)`.
# Every violation prints `file:line: reason` and the exit status is 1.
#
# --self-test builds a minimal conforming tree in a temporary directory, expects exit 0 on it
# and exit 1 after planting each violation in a copy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

APPKIT_ALLOWED="Sources/parbake/Setup.swift"
ENTRY_POINTS=(
    "Sources/parbake-agent/main.swift"
    "Sources/parbake/ParbakeTool.swift"
    "Sources/container-runtime-macos/RuntimeMacOSHelper+Start.swift"
)
SIGPIPE_LINE='signal(SIGPIPE, SIG_IGN)'

# Matches an import of module $1 with any attributes and access modifiers in front.
import_pattern() {
    printf '^[[:space:]]*(@[_A-Za-z]+[[:space:]]+|(public|internal|package|private|fileprivate)[[:space:]]+)*import[[:space:]]+(struct|class|enum|protocol|typealias|func|var|let)?[[:space:]]*%s([[:space:].;]|$)' "$1"
}

# check ROOT: prints violations, returns 1 when there are any.
check() {
    local root="$1" failed=0 file line pattern module entry
    if [[ ! -d "${root}/Sources" ]]; then
        printf '%s: no Sources directory\n' "${root}" >&2
        return 2
    fi

    pattern="$(import_pattern AppKit)"
    while IFS= read -r line; do
        file="${line%%:*}"
        [[ "${file#"${root}"/}" == "${APPKIT_ALLOWED}" ]] && continue
        printf '%s: import AppKit is allowed only in %s\n' "${line%%:[^:]*}" "${APPKIT_ALLOWED}"
        failed=1
    done < <(grep -rnE --include='*.swift' -e "${pattern}" "${root}/Sources" || true)

    if [[ -d "${root}/Sources/parbake-agent" ]]; then
        for module in RuntimeMacOS Virtualization; do
            pattern="$(import_pattern "${module}")"
            while IFS= read -r line; do
                printf '%s: parbake-agent must not import %s\n' "${line%:*}" "${module}"
                failed=1
            done < <(grep -rnE --include='*.swift' -e "${pattern}" "${root}/Sources/parbake-agent" || true)
        done
    fi

    for entry in "${ENTRY_POINTS[@]}"; do
        if [[ ! -f "${root}/${entry}" ]]; then
            printf '%s:1: entry point is missing\n' "${root}/${entry}"
            failed=1
        elif ! grep -qF -e "${SIGPIPE_LINE}" "${root}/${entry}"; then
            printf '%s:1: entry point lacks %s\n' "${root}/${entry}" "${SIGPIPE_LINE}"
            failed=1
        fi
    done
    return "${failed}"
}

# Writes a conforming tree below $1.
write_clean_tree() {
    local root="$1" entry
    for entry in "${ENTRY_POINTS[@]}"; do
        mkdir -p "${root}/$(dirname "${entry}")"
        printf 'import Foundation\n\n%s\n' "${SIGPIPE_LINE}" >"${root}/${entry}"
    done
    printf 'import AppKit\n' >"${root}/${APPKIT_ALLOWED}"
}

# expect_status DESCRIPTION WANT ROOT
expect_status() {
    local description="$1" want="$2" root="$3" got=0
    check "${root}" >/dev/null || got=$?
    if [[ "${got}" -ne "${want}" ]]; then
        printf 'self-test FAILED: %s: exit %s, want %s\n' "${description}" "${got}" "${want}" >&2
        return 1
    fi
    printf 'self-test ok: %s\n' "${description}"
}

self_test() {
    local base copy status=0 form
    WORK="$(mktemp -d)"
    trap 'rm -rf "${WORK}"' EXIT
    base="${WORK}/base"
    write_clean_tree "${base}"
    expect_status "clean tree passes" 0 "${base}" || status=1

    plant() { # plant DESCRIPTION FILE LINE
        copy="${WORK}/case"
        rm -rf "${copy}"
        cp -R "${base}" "${copy}"
        mkdir -p "${copy}/$(dirname "$2")"
        printf '%s\n' "$3" >>"${copy}/$2"
        expect_status "$1" 1 "${copy}" || status=1
    }

    plant "AppKit outside Setup.swift" Sources/parbake/Other.swift "import AppKit"
    plant "AppKit in an entry point" Sources/parbake/ParbakeTool.swift "import AppKit"
    for form in "import RuntimeMacOS" "@preconcurrency import RuntimeMacOS" "public import RuntimeMacOS" \
        "internal import RuntimeMacOS" "@_exported import RuntimeMacOS" "import Virtualization" \
        "@preconcurrency import Virtualization" "public import Virtualization" \
        "internal import Virtualization" "@_exported import Virtualization"; do
        plant "agent: ${form}" Sources/parbake-agent/Extra.swift "${form}"
    done

    local entry
    for entry in "${ENTRY_POINTS[@]}"; do
        copy="${WORK}/case"
        rm -rf "${copy}"
        cp -R "${base}" "${copy}"
        printf 'import Foundation\n' >"${copy}/${entry}"
        expect_status "no SIGPIPE in ${entry}" 1 "${copy}" || status=1
    done
    return "${status}"
}

main() {
    local root=""
    case "${1:-}" in
        --self-test)
            self_test
            return
            ;;
        -h | --help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            return
            ;;
    esac
    root="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
    check "${root}"
}

main "$@"
