#!/bin/bash
# SPDX-FileCopyrightText: 2026 Christian Semmelmann
# SPDX-License-Identifier: Apache-2.0

# Stamps and builds a tagged release.
#
# Usage:
#   release.sh stamp DIR X.Y.Z   Replace the development sentinel in DIR/Sources/ParbakeVersion.
#   release.sh build X.Y.Z       Build, sign and verify X.Y.Z in a sibling worktree.
#   release.sh --self-test       Prove the stamp guard and the version check.
#
# `stamp` needs exactly one `// STAMP:release` line under DIR/Sources, in ParbakeVersion.swift,
# and that line must hold "0.0.0-dev". `build` resolves the commit as vX.Y.Z when that tag exists,
# else HEAD, and requires it to be reachable from main (origin/main when main is absent). It
# creates a detached worktree beside the checkout, stamps it, runs `task check` there, checks that
# `parbake --version` and `container-runtime-macos --version` print X.Y.Z and that the agent binary
# carries X.Y.Z, then copies the three signed binaries to .build/release-assets/X.Y.Z/. Only the
# worktree it created is removed, on success or failure; the checkout's tracked files stay as they are.
#
# RELEASE_ALLOW_NON_MAIN=1 skips the ancestry check for a local dry run and prints a warning.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION_FILE="Sources/ParbakeVersion/ParbakeVersion.swift"
MARKER='// STAMP:release'
SENTINEL='0.0.0-dev'
BINARIES=(container-runtime-macos parbake parbake-agent)

die() {
    printf 'release.sh: %s\n' "$*" >&2
    return 1
}

valid_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version \"$1\" is not X.Y.Z"
}

# stamp DIR VERSION
stamp() {
    local dir="$1" version="$2" file count total line
    valid_version "${version}" || return 1
    file="${dir}/${VERSION_FILE}"
    [[ -f "${file}" ]] || die "${file} does not exist" || return 1
    count="$(grep -cF -e "${MARKER}" "${file}" || true)"
    [[ "${count}" -eq 1 ]] || die "${file} has ${count} ${MARKER} lines, want 1" || return 1
    total="$(grep -rF --include='*.swift' -e "${MARKER}" "${dir}/Sources" | wc -l | tr -d ' ')"
    [[ "${total}" -eq 1 ]] || die "${total} ${MARKER} lines under ${dir}/Sources, want 1" || return 1
    line="$(grep -F -e "${MARKER}" "${file}")"
    [[ "${line}" == *"\"${SENTINEL}\""* ]] || die "the ${MARKER} line lacks \"${SENTINEL}\": ${line}" || return 1
    sed "/STAMP:release/s/\"0\\.0\\.0-dev\"/\"${version}\"/" "${file}" >"${file}.stamp"
    mv "${file}.stamp" "${file}"
    line="$(grep -F -e "${MARKER}" "${file}")"
    [[ "${line}" == *"\"${version}\""* && "${line}" != *"${SENTINEL}"* ]] ||
        die "stamping ${file} failed: ${line}" || return 1
}

main_ref() {
    local ref
    for ref in main origin/main; do
        if git -C "${REPO_ROOT}" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
            printf '%s' "${ref}"
            return 0
        fi
    done
    die "neither main nor origin/main exists" || return 1
}

WORKTREE=""
cleanup() {
    if [[ -n "${WORKTREE}" ]]; then
        git -C "${REPO_ROOT}" worktree remove --force "${WORKTREE}" >/dev/null 2>&1 || true
        git -C "${REPO_ROOT}" worktree prune >/dev/null 2>&1 || true
        rmdir "${WORKTREE}" 2>/dev/null || true
    fi
}

# check_output BINARY VERSION: the binary's --version output is exactly VERSION.
check_output() {
    local binary="$1" want="$2" got
    got="$("${binary}" --version)"
    [[ "${got}" == "${want}" ]] || die "$(basename "${binary}") --version prints \"${got}\", want \"${want}\"" || return 1
    printf 'ok: %s --version = %s\n' "$(basename "${binary}")" "${got}"
}

build() {
    local version="${1:-}" commit base main bin_dir parent name binary assets
    valid_version "${version}" || return 1
    if git -C "${REPO_ROOT}" rev-parse --verify --quiet "refs/tags/v${version}^{commit}" >/dev/null; then
        commit="$(git -C "${REPO_ROOT}" rev-parse "refs/tags/v${version}^{commit}")"
    else
        commit="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
    fi
    if [[ "${RELEASE_ALLOW_NON_MAIN:-}" == 1 ]]; then
        printf 'warning: RELEASE_ALLOW_NON_MAIN=1 skips the main ancestry check; a local dry run only\n' >&2
    else
        main="$(main_ref)" || return 1
        git -C "${REPO_ROOT}" merge-base --is-ancestor "${commit}" "${main}" ||
            die "${commit} is not reachable from ${main}" || return 1
    fi

    parent="$(dirname "${REPO_ROOT}")"
    name="$(basename "${REPO_ROOT}")"
    base="$(mktemp -d "${parent}/${name}-release-${version}-XXXXXX")"
    WORKTREE="${base}"
    trap cleanup EXIT
    git -C "${REPO_ROOT}" worktree add --detach "${WORKTREE}" "${commit}"

    stamp "${WORKTREE}" "${version}"
    (cd "${WORKTREE}" && task check)
    bin_dir="$(cd "${WORKTREE}" && task bin-path)"
    check_output "${bin_dir}/parbake" "${version}"
    check_output "${bin_dir}/container-runtime-macos" "${version}"
    # The agent has no command that prints its line without a guest; its line is "1 <release>"
    # from the stamped constant, so the binary must carry the version.
    grep -aqF -e "${version}" "${bin_dir}/parbake-agent" || die "parbake-agent does not carry ${version}" || return 1
    if grep -qF -e "${SENTINEL}" "${WORKTREE}/${VERSION_FILE}"; then
        die "sentinel left in the stamped source" || return 1
    fi
    printf 'ok: parbake-agent carries %s (agent line: 1 %s)\n' "${version}" "${version}"

    assets="${REPO_ROOT}/.build/release-assets/${version}"
    mkdir -p "${assets}"
    for binary in "${BINARIES[@]}"; do
        cp "${bin_dir}/${binary}" "${assets}/${binary}"
    done
    printf 'release assets: %s\n' "${assets}"
}

# --- self-test -------------------------------------------------------------------------------

STATUS=0
WORK=""
expect() { # expect DESCRIPTION WANT(0|1) COMMAND...
    local description="$1" want="$2" got=0
    shift 2
    "$@" >/dev/null 2>&1 || got=$?
    [[ "${got}" -ge 1 ]] && got=1
    if [[ "${got}" -ne "${want}" ]]; then
        printf 'self-test FAILED: %s: exit %s, want %s\n' "${description}" "${got}" "${want}" >&2
        STATUS=1
    else
        printf 'self-test ok: %s\n' "${description}"
    fi
}

plant() { # plant DIR CONTENT
    rm -rf "$1"
    mkdir -p "$1/Sources/ParbakeVersion"
    printf '%s\n' "$2" >"$1/${VERSION_FILE}"
}

self_test() {
    local work real marked dir version before after
    WORK="$(mktemp -d)"
    work="${WORK}"
    trap 'rm -rf "${WORK}"' EXIT
    marked='    public static let release = "0.0.0-dev"  // STAMP:release'
    dir="${work}/case"

    plant "${dir}" '    public static let release = "0.0.0-dev"'
    expect "missing marker" 1 stamp "${dir}" 1.2.3
    plant "${dir}" "${marked}"$'\n'"${marked}"
    expect "duplicate marker" 1 stamp "${dir}" 1.2.3
    plant "${dir}" "${marked}"
    mkdir -p "${dir}/Sources/Other"
    printf '%s\n' "${marked}" >"${dir}/Sources/Other/Other.swift"
    expect "marker in a second file" 1 stamp "${dir}" 1.2.3
    plant "${dir}" '    public static let release = "0.1.0"  // STAMP:release'
    expect "marker without sentinel" 1 stamp "${dir}" 1.2.3
    plant "${dir}" "${marked}"
    for version in 1.2 v1.2.3 1.2.3-rc1 1.2.3+meta ""; do
        expect "bad version \"${version}\"" 1 stamp "${dir}" "${version}"
    done

    real="${work}/real"
    mkdir -p "${real}/Sources/ParbakeVersion"
    # A stamped tree (the release worktree runs this test) is reset to the sentinel first.
    sed '/STAMP:release/s/"[^"]*"/"0.0.0-dev"/' "${REPO_ROOT}/${VERSION_FILE}" >"${real}/${VERSION_FILE}"
    expect "real file stamps 1.2.3" 0 stamp "${real}" 1.2.3
    if grep -qF '"1.2.3"' "${real}/${VERSION_FILE}" && ! grep -qF "${SENTINEL}" "${real}/${VERSION_FILE}"; then
        printf 'self-test ok: stamped file holds "1.2.3" and no sentinel\n'
    else
        printf 'self-test FAILED: stamped file content\n' >&2
        STATUS=1
    fi

    before="$(git -C "${REPO_ROOT}" worktree list)"
    for version in 1.2 v1.2.3 1.2.3-rc1 ""; do
        expect "build refuses \"${version}\"" 1 "${BASH_SOURCE[0]}" build "${version}"
    done
    after="$(git -C "${REPO_ROOT}" worktree list)"
    if [[ "${before}" == "${after}" ]]; then
        printf 'self-test ok: no worktree created for a bad version\n'
    else
        printf 'self-test FAILED: a worktree appeared\n' >&2
        STATUS=1
    fi
    return "${STATUS}"
}

main() {
    case "${1:-}" in
        --self-test) self_test ;;
        stamp)
            [[ $# -eq 3 ]] || die "usage: release.sh stamp DIR X.Y.Z" || return 1
            stamp "$2" "$3"
            ;;
        build)
            [[ $# -eq 2 ]] || die "usage: release.sh build X.Y.Z" || return 1
            build "$2"
            ;;
        -h | --help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' ;;
        *) die "usage: release.sh stamp DIR X.Y.Z | build X.Y.Z | --self-test" ;;
    esac
}

main "$@"
