#!/bin/bash
# SPDX-FileCopyrightText: 2026 Christian Semmelmann
# SPDX-License-Identifier: Apache-2.0

# --- usage ---
# Builds the OCX package of the Parbake plugin: container-runtime-macos, parbake and parbake-agent.
#
# Usage:
#   package.sh stage VERSION    Build the plugin root from the stamped release assets and config.toml.
#   package.sh verify           Check signatures and entitlements of the plugin root.
#   package.sh create VERSION   Run ocx package create into .build/package/.
#   package.sh pair             Check that the container tag builds the revision Package.resolved pins.
#   package.sh all VERSION      Run pair, stage, verify and create in order.
#   package.sh --self-test      Offline checks of every step.
#   package.sh -h | --help      Print this usage.
#
# Paths are relative to the repository root: the plugin root .build/package/root, the archive
# .build/package/parbake-X.Y.Z.tar.xz and the stamp .build/package/verified. PACKAGE_PAIR_LOCATION
# points pair at another fork location, for a dry run before the fork tag exists.
#
# Exit codes: 0 success; 1 a failed step; 2 a usage error.
# --- end usage ---
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PKG_BASE="${REPO_ROOT}/.build/package"
FIXTURES="${SCRIPT_DIR}/fixtures/package"
METADATA="${REPO_ROOT}/packaging/metadata.json"
PACKAGE_RESOLVED="${REPO_ROOT}/Package.resolved"
CONTAINER_TAG_FILE="${REPO_ROOT}/packaging/container.tag"
ASSETS_BASE="${REPO_ROOT}/.build/release-assets"

PARBAKE_BINARIES=(container-runtime-macos parbake parbake-agent)
CONTAINER_TAG_RE='^[0-9]+\.[0-9]+\.[0-9]+_[0-9]{2}$'
FORK_LOCATION_RE='^https://github\.com/extra-code/container(\.git)?$'
ENTITLEMENT="com.apple.security.virtualization"
# Binaries that must carry the virtualization entitlement, and the one that must not.
ENTITLED="container-runtime-macos parbake"
UNENTITLED="parbake-agent"
# Every entry of the plugin root, and nothing else.
ROOT_ENTRIES=(bin bin/container-runtime-macos bin/parbake bin/parbake-agent config.toml)

PROBLEMS=0

die() {
    printf 'package.sh: %s\n' "$*" >&2
    return 1
}

usage_error() {
    printf 'package.sh: %s\n' "$*" >&2
    printf 'usage: package.sh stage VERSION | verify | create VERSION | pair | all VERSION | --self-test | -h\n' >&2
    return 2
}

is_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

valid_version() {
    is_version "$1" || usage_error "version \"$1\" is not X.Y.Z"
}

# resolve_path PATH: the absolute form with symlinks resolved in the existing part; a ".." component
# is refused because the rest of the path may not exist yet.
resolve_path() {
    local path="$1" rest="" part
    [[ "${path}" == /* ]] || path="$(pwd)/${path}"
    case "/${path}/" in
        */../*) return 1 ;;
    esac
    while [[ ! -d "${path}" && "${path}" != / ]]; do
        part="$(basename "${path}")"
        rest="/${part}${rest}"
        path="$(dirname "${path}")"
    done
    path="$(cd -P "${path}" && pwd)"
    [[ "${path}" == / ]] && path=""
    printf '%s%s' "${path}" "${rest}"
}

# safe_rm PATH: rm -rf PATH, only when PATH is strictly below PKG_BASE.
safe_rm() {
    local path="${1:-}" resolved base
    [[ -n "${path}" ]] || die "refusing to remove \"${path}\"" || return 1
    resolved="$(resolve_path "${path}")" || die "refusing to remove ${path}" || return 1
    base="$(resolve_path "${PKG_BASE}")" || die "refusing to remove ${path}" || return 1
    [[ "${resolved}" == "${base}/"* && "${resolved}" != "${base}/" ]] || die "refusing to remove ${path}" || return 1
    rm -rf -- "${resolved}"
}

# pin_field FILE FIELD: a field (location or revision) of the container pin in a Package.resolved.
pin_field() {
    awk -v field="\"$2\"" '
        $1 == "\"identity\"" { pin = ($3 == "\"container\",") }
        pin && $1 == field { gsub(/[",]/, "", $3); print $3; exit }
    ' "$1"
}

# fork_pin FILE: prints the fork's location and revision, one per line, after checking both.
fork_pin() {
    local file="$1" location revision
    location="$(pin_field "${file}" location)"
    revision="$(pin_field "${file}" revision)"
    [[ -n "${location}" && -n "${revision}" ]] || die "pair: fork pin not found in $(basename "${file}")" || return 1
    [[ "${location}" =~ ${FORK_LOCATION_RE} ]] || die "pair: invalid fork pin: location \"${location}\" is not the extra-code/container https URL" || return 1
    [[ "${revision}" =~ ^[0-9a-f]{40}$ ]] || die "pair: invalid fork pin: revision \"${revision}\" is not 40 hex digits" || return 1
    printf '%s\n%s\n' "${location}" "${revision}"
}

# pair: the container tag builds the revision Package.resolved pins. Needs the network, unless
# PACKAGE_PAIR_LOCATION points at another fork: a file:// URL.
pair() {
    local tag pin location revision fetch_from gitdir rc=0
    if [[ ! -f "${CONTAINER_TAG_FILE}" ]]; then
        printf 'no container tag, pairing skipped\n'
        return 0
    fi
    tag="$(<"${CONTAINER_TAG_FILE}")"
    tag="${tag//$'\r'/}"
    tag="${tag%"${tag##*[![:space:]]}"}"
    [[ "${tag}" =~ ${CONTAINER_TAG_RE} ]] || die "pair: invalid container tag \"${tag}\"" || return 1
    pin="$(fork_pin "${PACKAGE_RESOLVED}")" || return 1
    location="${pin%%$'\n'*}"
    revision="${pin##*$'\n'}"
    fetch_from="${PACKAGE_PAIR_LOCATION:-${location}}"
    if [[ -n "${PACKAGE_PAIR_LOCATION:-}" && "${PACKAGE_PAIR_LOCATION}" != file://* ]]; then
        usage_error "PACKAGE_PAIR_LOCATION must be a file:// URL, got \"${PACKAGE_PAIR_LOCATION}\"" || return 1
    fi
    mkdir -p "${PKG_BASE}" || die "pair: cannot create ${PKG_BASE}" || return 1
    gitdir="$(mktemp -d "${PKG_BASE}/pair.XXXXXX")" || die "pair: cannot make a temp directory" || return 1
    pair_fetch "${gitdir}" "${fetch_from}" "${tag}" "${revision}" || rc=$?
    safe_rm "${gitdir}" || rc=1
    return "${rc}"
}

# pair_fetch GITDIR FROM TAG REVISION: fetch the tag into GITDIR and compare its source revision.
pair_fetch() {
    local gitdir="$1" fetch_from="$2" tag="$3" revision="$4" built err
    git init --bare -q "${gitdir}" || die "pair: cannot make a git directory" || return 1
    err="$(GIT_TERMINAL_PROMPT=0 git --git-dir="${gitdir}" fetch --depth 1 --no-tags -q -- "${fetch_from}" "refs/tags/ocx-${tag}" 2>&1 >/dev/null)" ||
        die "pair: container tag ocx-${tag} not found: ${err%%$'\n'*}" || return 1
    built="$(git --git-dir="${gitdir}" show 'FETCH_HEAD^{commit}:ocx/source-revision' 2>/dev/null)" ||
        die "pair: container tag ocx-${tag} has no ocx/source-revision" || return 1
    built="$(tr -d '[:space:]' <<<"${built}")"
    [[ "${built}" == "${revision}" ]] ||
        die "pair: container tag ocx-${tag} builds ${built}, Package.resolved pins ${revision}" || return 1
    printf 'container tag ocx-%s builds the pinned revision %s\n' "${tag}" "${revision}"
}

# release_commit VERSION: the vVERSION tag when it exists, else HEAD, as release.sh resolves it.
release_commit() {
    if git -C "${REPO_ROOT}" rev-parse --verify --quiet "refs/tags/v$1^{commit}" >/dev/null; then
        git -C "${REPO_ROOT}" rev-parse "refs/tags/v$1^{commit}"
    else
        git -C "${REPO_ROOT}" rev-parse HEAD
    fi
}

# stage_copy ASSETS ROOT COMMIT VERSION: the plugin root from the three binaries and config.toml.
stage_copy() {
    local assets="$1" root="$2" commit="$3" version="$4" name
    for name in "${PARBAKE_BINARIES[@]}"; do
        [[ -f "${assets}/${name}" ]] ||
            die "stage: ${assets}/${name} is missing; run task release:build VERSION=${version} first" || return 1
    done
    safe_rm "${root}" || return 1
    mkdir -p "${root}/bin" || die "stage: cannot create ${root}/bin" || return 1
    for name in "${PARBAKE_BINARIES[@]}"; do
        cp -p "${assets}/${name}" "${root}/bin/${name}" || die "stage: cannot copy ${name}" || return 1
        chmod 0755 "${root}/bin/${name}" || die "stage: cannot chmod ${name}" || return 1
    done
    git -C "${REPO_ROOT}" show "${commit}:config.toml" >"${root}/config.toml" ||
        die "stage: cannot read config.toml at ${commit}" || return 1
    chmod 0644 "${root}/config.toml" || die "stage: cannot chmod config.toml" || return 1
}

# stage_versions ROOT VERSION: the staged parbake and container-runtime-macos print VERSION.
stage_versions() {
    local root="$1" version="$2" name got
    for name in parbake container-runtime-macos; do
        got="$("${root}/bin/${name}" --version)" || die "stage: ${name} --version failed" || return 1
        [[ "${got}" == "${version}" ]] || die "stage: ${name} --version prints \"${got}\", want \"${version}\"" || return 1
    done
}

stage() {
    local version="$1" root="${PKG_BASE}/root"
    stage_copy "${ASSETS_BASE}/${version}" "${root}" "$(release_commit "${version}")" "${version}" || return 1
    stage_versions "${root}" "${version}" || return 1
    printf 'staged Parbake %s into %s\n' "${version}" "${root}"
}

problem() {
    printf 'package.sh: verify: %s\n' "$*" >&2
    PROBLEMS=$((PROBLEMS + 1))
}

# entitlement_dump FILE: the entitlements plist of a signed file; fails when codesign cannot read it.
entitlement_dump() {
    codesign -d --entitlements :- "$1" 2>/dev/null
}

# entitlement_keys DUMP: the entitlement keys in a plist, one per line.
entitlement_keys() {
    awk '{
        while (match($0, /<key>[^<]*<\/key>/)) {
            print substr($0, RSTART + 5, RLENGTH - 11)
            $0 = substr($0, RSTART + RLENGTH)
        }
    }' <<<"$1"
}

# entitlement_is_true DUMP: the virtualization entitlement is present with the value true.
entitlement_is_true() {
    local flat
    flat="$(tr -d ' \t\n' <<<"$1")"
    [[ "${flat}" == *"<key>${ENTITLEMENT}</key><true/>"* ]]
}

# is_adhoc SIGNATURE_INFO: the text of codesign -dv names an ad-hoc signature.
is_adhoc() {
    [[ "$1" == *"Signature=adhoc"* ]]
}

# verify_file FILE: signature and entitlement problems of one Mach-O file.
verify_file() {
    local file="$1" name info dump keys key want
    name="$(basename "${file}")"
    codesign --verify --strict "${file}" >/dev/null 2>&1 || problem "bad signature: ${file}"
    info="$(codesign -dv "${file}" 2>&1)" || problem "cannot read the signature: ${file}"
    is_adhoc "${info}" || problem "signature is not ad-hoc: ${file}"
    dump="$(entitlement_dump "${file}")" || {
        problem "cannot read the entitlements: ${file}"
        dump=""
    }
    keys="$(entitlement_keys "${dump}")"
    for key in ${keys}; do
        [[ "${key}" == "${ENTITLEMENT}" ]] || problem "unexpected entitlement ${key}: ${file}"
    done
    case " ${ENTITLED} " in *" ${name} "*) want=1 ;; *) want=0 ;; esac
    if [[ "${want}" -eq 1 ]]; then
        if [[ "${keys}" != *"${ENTITLEMENT}"* ]]; then
            problem "missing ${ENTITLEMENT}: ${file}"
        elif ! entitlement_is_true "${dump}"; then
            problem "${ENTITLEMENT} is not true: ${file}"
        fi
    elif [[ " ${UNENTITLED} " == *" ${name} "* && "${keys}" == *"${ENTITLEMENT}"* ]]; then
        problem "${ENTITLEMENT} must be absent: ${file}"
    fi
}

# verify_entries ROOT SCANS: the root holds exactly ROOT_ENTRIES; SCANS holds the entry listing.
verify_entries() {
    local root="$1" scans="$2" entry rel known item
    find "${root}" -mindepth 1 -print0 >"${scans}/entries" || problem "cannot scan ${root}"
    while IFS= read -r -d '' entry; do
        rel="${entry#"${root}"/}"
        known=0
        for item in "${ROOT_ENTRIES[@]}"; do
            [[ "${rel}" == "${item}" ]] && known=1
        done
        [[ "${known}" -eq 1 ]] || problem "unexpected entry: ${entry}"
    done <"${scans}/entries"
    for item in "${ROOT_ENTRIES[@]}"; do
        [[ -e "${root}/${item}" || -L "${root}/${item}" ]] || problem "missing entry: ${root}/${item}"
    done
}

# is_member WORD LIST...: WORD equals one of the list entries exactly.
is_member() {
    local want="$1" entry
    shift
    for entry in "$@"; do
        [[ "${entry}" == "${want}" ]] && return 0
    done
    return 1
}

# verify_root ROOT: entries, signatures, entitlements, modes, links and quarantine of the plugin root.
verify_root() {
    local root="$1" file ftype xattrs real top name scans
    local machos=()
    PROBLEMS=0
    [[ -d "${root}" ]] || die "verify: no plugin root at ${root}; run stage first" || return 1
    top="$(cd -P "${root}" && pwd)"
    scans="$(mktemp -d)" || die "verify: cannot make a temp directory" || return 1
    verify_entries "${root}" "${scans}"
    find "${root}" -type f -print0 >"${scans}/files" || problem "cannot scan ${root}"
    find "${root}" ! -type l \( -perm -4000 -o -perm -2000 -o -perm -0002 \) -print0 >"${scans}/modes" ||
        problem "cannot scan ${root} for setuid and world-writable files"
    find "${root}" -type l -print0 >"${scans}/links" || problem "cannot scan ${root} for symlinks"
    while IFS= read -r -d '' file; do
        ftype="$(file -b "${file}")" || {
            problem "cannot identify the file type: ${file}"
            continue
        }
        [[ "${ftype}" == *Mach-O* ]] || continue
        machos+=("${file}")
        verify_file "${file}"
    done <"${scans}/files"
    [[ "${#machos[@]}" -gt 0 ]] || problem "no Mach-O file under ${root}"
    for name in "${PARBAKE_BINARIES[@]}"; do
        is_member "${root}/bin/${name}" "${machos[@]+"${machos[@]}"}" || [[ ! -f "${root}/bin/${name}" ]] ||
            problem "not a Mach-O file: ${root}/bin/${name}"
        [[ ! -f "${root}/bin/${name}" || -x "${root}/bin/${name}" ]] || problem "not executable: ${root}/bin/${name}"
    done
    while IFS= read -r -d '' file; do
        problem "setuid, setgid or world-writable: ${file}"
    done <"${scans}/modes"
    while IFS= read -r -d '' file; do
        real="$(realpath "${file}" 2>/dev/null)" || real=""
        problem "symlink: ${file}"
        [[ "${real}" == "${top}" || "${real}" == "${top}/"* ]] || problem "symlink leaves the root: ${file}"
    done <"${scans}/links"
    xattrs="$(xattr -rl "${root}" 2>&1)" || problem "cannot read the extended attributes of ${root}"
    [[ "${xattrs}" != *com.apple.quarantine* ]] || problem "a file carries com.apple.quarantine"
    rm -rf "${scans}"
    [[ "${PROBLEMS}" -eq 0 ]] || die "verify: ${PROBLEMS} problem(s) in ${root}" || return 1
}

# verify: checks the plugin root and stamps it with the staged Parbake version.
verify() {
    local root="${PKG_BASE}/root" version
    verify_root "${root}" || return 1
    version="$("${root}/bin/parbake" --version)" || die "verify: parbake --version failed" || return 1
    is_version "${version}" || die "verify: parbake --version prints \"${version}\"" || return 1
    printf '%s\n' "${version}" >"${PKG_BASE}/verified" || die "verify: cannot write the stamp ${PKG_BASE}/verified" || return 1
    printf 'verified %s: stamp %s\n' "${root}" "${version}"
}

# check_stamp STAMP ROOT VERSION: the stamp exists, holds VERSION and is newer than every file in ROOT.
check_stamp() {
    local stamp="$1" root="$2" version="$3" newer
    [[ -f "${stamp}" ]] || die "create: ${stamp} is missing; run verify first" || return 1
    [[ "$(cat "${stamp}")" == "${version}" ]] ||
        die "create: ${stamp} holds \"$(cat "${stamp}")\", want \"${version}\"; run verify again" || return 1
    newer="$(find "${root}" -newer "${stamp}" -print -quit)"
    [[ -z "${newer}" ]] || die "create: ${newer} is newer than the stamp; run verify again" || return 1
}

# check_archive ARCHIVE: no absolute and no .. member.
check_archive() {
    local listing
    listing="$(tar -tf "$1")" || die "create: cannot list $1" || return 1
    if grep -Eq '^/|(^|/)\.\.(/|$)' <<<"${listing}"; then
        die "create: $1 has an absolute or .. member" || return 1
    fi
}

# create VERSION: the archive and its compiled metadata (parbake-VERSION-metadata.json) in PKG_BASE.
create() {
    local version="$1" root="${PKG_BASE}/root" archive="${PKG_BASE}/parbake-$1.tar.xz" name
    check_stamp "${PKG_BASE}/verified" "${root}" "${version}" || return 1
    # ocx package create writes parbake-VERSION-receipt.json beside the archive; drop a stale one.
    for name in "${archive}" "${PKG_BASE}/parbake-${version}-metadata.json" "${PKG_BASE}/parbake-${version}-receipt.json"; do
        safe_rm "${name}" || return 1
    done
    ocx package create "${root}" -p darwin/arm64 -m "${METADATA}" --bin-scan -o "${archive}" ||
        die "create: ocx package create failed" || return 1
    [[ -f "${archive}" ]] || die "create: ${archive} was not written" || return 1
    [[ -f "${PKG_BASE}/parbake-${version}-metadata.json" ]] ||
        die "create: ${PKG_BASE}/parbake-${version}-metadata.json was not written" || return 1
    check_archive "${archive}" || return 1
    printf 'archive: %s\nmetadata: %s\n' "${archive}" "${PKG_BASE}/parbake-${version}-metadata.json"
}

all() {
    local version="$1"
    pair || return 1
    stage "${version}" || return 1
    verify || return 1
    create "${version}" || return 1
}

usage() {
    sed -n '/^# --- usage ---$/,/^# --- end usage ---$/p' "$0" | sed '1d;$d' | sed 's/^# \{0,1\}//'
}

# --- self-test -------------------------------------------------------------------------------

STATUS=0
WORK=""

pass() { printf 'self-test ok: %s\n' "$1"; }
fail() {
    printf 'self-test FAILED: %s\n' "$1" >&2
    STATUS=1
}

# expect_code DESCRIPTION WANT COMMAND...: the command exits with exactly WANT.
expect_code() {
    local description="$1" want="$2" got=0
    shift 2
    "$@" >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
        pass "${description}"
    else
        fail "${description}: exit ${got}, want ${want}"
    fi
}

# expect_fail DESCRIPTION COMMAND...: the command exits non-zero.
expect_fail() {
    local description="$1" got=0
    shift
    "$@" >/dev/null 2>&1 || got=$?
    if [[ "${got}" -ne 0 ]]; then
        pass "${description}"
    else
        fail "${description}: succeeded"
    fi
}

# the usage text and the exit codes.
self_test_usage() {
    local out
    out="$("${BASH_SOURCE[0]}" --help)" || fail "--help exits non-zero"
    if [[ "${out}" == *"Usage:"* && "${out}" == *"--self-test"* && "${out}" != *"--- usage ---"* ]]; then
        pass "--help prints the usage header"
    else
        fail "--help output"
    fi
    expect_code "-h exits 0" 0 "${BASH_SOURCE[0]}" -h
    expect_code "no subcommand exits 2" 2 "${BASH_SOURCE[0]}"
    expect_code "unknown subcommand exits 2" 2 "${BASH_SOURCE[0]}" frobnicate
    expect_code "fetch is removed and exits 2" 2 "${BASH_SOURCE[0]}" fetch
    expect_code "build is removed and exits 2" 2 "${BASH_SOURCE[0]}" build
    local sub version
    for sub in stage create all; do
        expect_code "${sub} without VERSION exits 2" 2 "${BASH_SOURCE[0]}" "${sub}"
        for version in 1.2 v1.2.3 1.2.3-rc1 ""; do
            expect_code "${sub} \"${version}\" exits 2" 2 "${BASH_SOURCE[0]}" "${sub}" "${version}"
        done
    done
}

# packaging/metadata.json is valid JSON.
self_test_metadata() {
    if python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' "${METADATA}" 2>/dev/null; then
        pass "packaging/metadata.json parses as JSON"
    else
        fail "packaging/metadata.json does not parse"
    fi
}

# the metadata declares a bundle of version 1 with the single PATH entry ${installPath}/bin.
self_test_metadata_shape() {
    local out
    out="$(
        python3 -I - "${METADATA}" <<'PY' 2>&1
import json, sys
m = json.load(open(sys.argv[1]))
assert m.get("type") == "bundle", "type"
assert m.get("version") == 1, "version"
env = m.get("env")
assert isinstance(env, list) and len(env) == 1, "env must hold one entry"
e = env[0]
assert e.get("key") == "PATH" and e.get("type") == "path", "entry must be the PATH path"
assert e.get("value") == "${installPath}/bin", "value"
PY
    )" || {
        fail "packaging/metadata.json shape: ${out}"
        return
    }
    pass "packaging/metadata.json is a version 1 bundle with the PATH entry \${installPath}/bin"
}

# metadata_binaries: the binaries listed in packaging/metadata.json, sorted, one per line.
metadata_binaries() {
    python3 -I -c 'import json, sys; print("\n".join(sorted(json.load(open(sys.argv[1]))["binaries"])))' "${METADATA}"
}

# the metadata binaries are exactly the Parbake binaries.
self_test_metadata_binaries() {
    local staged wanted
    staged="$(printf '%s\n' "${PARBAKE_BINARIES[@]}" | sort)"
    wanted="$(metadata_binaries)" || {
        fail "cannot read the metadata binaries"
        return
    }
    if [[ "${staged}" == "${wanted}" ]]; then
        pass "the metadata binaries are the Parbake binaries"
    else
        fail "metadata binaries differ: metadata $(tr '\n' ' ' <<<"${wanted}")wanted $(tr '\n' ' ' <<<"${staged}")"
    fi
}

# the fork pin parsing, offline.
self_test_pin() {
    local dir="$1" out
    out="$(fork_pin "${FIXTURES}/Package.resolved" 2>&1)" || fail "fork_pin fails on the fixture: ${out}"
    if [[ "${out}" == "https://github.com/extra-code/container.git"$'\n'"0f8245481903d4db3fe701bbf0750924b450bc4d" ]]; then
        pass "fork_pin returns the fixture location and revision"
    else
        fail "fork_pin output: ${out}"
    fi
    out="$(fork_pin "${FIXTURES}/Package.resolved.nofork" 2>&1)" && fail "fork_pin accepts a fixture without the fork"
    if [[ "${out}" == *"fork pin not found in Package.resolved"* ]]; then
        pass "fork_pin names a missing fork pin"
    else
        fail "missing fork message: ${out}"
    fi
    sed 's/"revision" : "0f8245481903d4db3fe701bbf0750924b450bc4d"/"revision" : "0f82454"/' \
        "${FIXTURES}/Package.resolved" >"${dir}/short-revision"
    sed 's#https://github.com/extra-code/container.git#http://github.com/extra-code/container.git#' \
        "${FIXTURES}/Package.resolved" >"${dir}/http-location"
    sed 's/"revision" : "0f8245481903d4db3fe701bbf0750924b450bc4d"/"revision" : "0F8245481903D4DB3FE701BBF0750924B450BC4D"/' \
        "${FIXTURES}/Package.resolved" >"${dir}/upper-revision"
    local bad
    sed 's#https://github.com/extra-code/container.git#https://example.com/extra-code/container.git#' \
        "${FIXTURES}/Package.resolved" >"${dir}/other-host"
    for bad in short-revision http-location upper-revision other-host; do
        out="$(fork_pin "${dir}/${bad}" 2>&1)" && fail "fork_pin accepts ${bad}"
        if [[ "${out}" == *"invalid fork pin"* ]]; then
            pass "fork_pin rejects ${bad}"
        else
            fail "${bad} message: ${out}"
        fi
    done
}

# expect_message DESCRIPTION TEXT COMMAND...: the command fails and its output contains TEXT.
expect_message() {
    local description="$1" text="$2" out got=0
    shift 2
    out="$("$@" 2>&1)" || got=$?
    if [[ "${got}" -ne 0 && "${out}" == *"${text}"* ]]; then
        pass "${description}"
    else
        fail "${description}: exit ${got}, output: ${out}"
    fi
}

# make_assets DIR VERSION [PRINTED]: stub binaries that print PRINTED (default VERSION) for --version.
make_assets() {
    local dir="$1/$2" name
    mkdir -p "${dir}"
    for name in "${PARBAKE_BINARIES[@]}"; do
        printf '#!/bin/sh\necho %s\n' "${3:-$2}" >"${dir}/${name}"
        chmod 0755 "${dir}/${name}"
    done
}

# stage on stub assets: the missing asset, the plugin root content and the version checks.
self_test_stage() {
    local base="$1/stage" root name mode
    PKG_BASE="${base}"
    ASSETS_BASE="${base}/assets"
    root="${base}/root"
    mkdir -p "${base}"
    expect_message "stage fails and names the build task when an asset is missing" \
        "run task release:build VERSION=0.1.0 first" stage 0.1.0
    make_assets "${ASSETS_BASE}" 0.1.0
    expect_code "stage succeeds on stub assets" 0 stage 0.1.0
    for name in "${PARBAKE_BINARIES[@]}"; do
        mode="$(stat -f '%Lp' "${root}/bin/${name}" 2>/dev/null || true)"
        if [[ "${mode}" == 755 ]] && cmp -s "${root}/bin/${name}" "${ASSETS_BASE}/0.1.0/${name}"; then
            pass "stage copies ${name} unchanged with mode 0755"
        else
            fail "stage did not copy ${name} (mode ${mode})"
        fi
    done
    mode="$(stat -f '%Lp' "${root}/config.toml" 2>/dev/null || true)"
    if [[ "${mode}" == 644 ]] && git -C "${REPO_ROOT}" show "$(release_commit 0.1.0):config.toml" | cmp -s - "${root}/config.toml"; then
        pass "stage writes config.toml at the plugin root with mode 0644"
    else
        fail "config.toml is not at the plugin root (mode ${mode})"
    fi
    if [[ "$(find "${root}" -mindepth 1 | wc -l | tr -d ' ')" -eq 5 ]]; then
        pass "the staged root holds the directory bin, three binaries and config.toml"
    else
        fail "the staged root has other entries"
    fi
    printf 'x' >"${root}/stale"
    expect_code "stage recreates the root" 0 stage 0.1.0
    if [[ ! -e "${root}/stale" ]]; then
        pass "stage drops what the root held before"
    else
        fail "stage kept a stale file"
    fi
    make_assets "${ASSETS_BASE}" 0.1.1 0.1.0
    expect_message "stage refuses a parbake that prints another version" "want \"0.1.1\"" stage 0.1.1
    ASSETS_BASE="${REPO_ROOT}/.build/release-assets"
}

# sign_copy FILE [ENTITLEMENTS [SOURCE]]: replaces FILE with an ad-hoc signed copy of SOURCE
# (default /usr/bin/true).
sign_copy() {
    mkdir -p "$(dirname "$1")"
    cp "${3:-/usr/bin/true}" "$1"
    chmod 0755 "$1"
    if [[ -n "${2:-}" ]]; then
        codesign -s - -f --entitlements "$2" "$1" >/dev/null 2>&1
    else
        codesign -s - -f "$1" >/dev/null 2>&1
    fi
}

# expect_problem DESCRIPTION TEXT ROOT: verify_root fails on ROOT and its report contains TEXT.
expect_problem() {
    local out got=0
    out="$(verify_root "$3" 2>&1)" || got=$?
    if [[ "${got}" -ne 0 && "${out}" == *"$2"* ]]; then
        pass "$1"
    else
        fail "$1: exit ${got}, report: ${out}"
    fi
}

# entitlement and signature parsing on captured sample text.
self_test_parsing() {
    local plist='<plist><dict><key>com.apple.security.virtualization</key>
    <true/></dict></plist>'
    expect_code "entitlement_is_true accepts true" 0 entitlement_is_true "${plist}"
    expect_fail "entitlement_is_true refuses false" entitlement_is_true "${plist//<true\/>/<false/>}"
    expect_fail "entitlement_is_true refuses an empty dump" entitlement_is_true ""
    expect_code "is_adhoc accepts an ad-hoc signature" 0 is_adhoc $'Identifier=a\nSignature=adhoc\nTeamIdentifier=not set'
    expect_fail "is_adhoc refuses a signing identity" is_adhoc $'Identifier=a\nAuthority=Developer ID Application: X\nSignature size=9012'
}

# verify_root on a good root and on roots that break one rule each.
self_test_verify() {
    local dir="$1/verify" ent="$1/verify/virt.plist" extra="$1/verify/extra.plist" good bad
    mkdir -p "${dir}"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>%s</key><true/></dict></plist>\n' \
        "${ENTITLEMENT}" >"${ent}"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>%s</key><true/><key>com.apple.security.get-task-allow</key><true/></dict></plist>\n' \
        "${ENTITLEMENT}" >"${extra}"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>%s</key><false/></dict></plist>\n' \
        "${ENTITLEMENT}" >"${dir}/false.plist"
    good="${dir}/good"
    sign_copy "${good}/bin/container-runtime-macos" "${ent}"
    sign_copy "${good}/bin/parbake" "${ent}"
    sign_copy "${good}/bin/parbake-agent"
    cp "${REPO_ROOT}/config.toml" "${good}/config.toml"
    expect_code "verify_root accepts a good root" 0 verify_root "${good}"

    bad="${dir}/extra-file"
    cp -R "${good}" "${bad}"
    printf 'x' >"${bad}/notes.txt"
    expect_problem "verify_root refuses an extra file" "unexpected entry: ${bad}/notes.txt" "${bad}"

    bad="${dir}/missing-file"
    cp -R "${good}" "${bad}"
    rm "${bad}/config.toml"
    expect_problem "verify_root refuses a missing file" "missing entry: ${bad}/config.toml" "${bad}"

    bad="${dir}/broken"
    cp -R "${good}" "${bad}"
    printf 'x' >>"${bad}/bin/parbake"
    expect_problem "verify_root refuses a modified binary" "bad signature" "${bad}"

    bad="${dir}/agent-entitled"
    cp -R "${good}" "${bad}"
    sign_copy "${bad}/bin/parbake-agent" "${ent}"
    expect_problem "verify_root refuses the virtualization entitlement on the agent" "must be absent" "${bad}"

    bad="${dir}/extra-entitlement"
    cp -R "${good}" "${bad}"
    sign_copy "${bad}/bin/parbake" "${extra}"
    expect_problem "verify_root refuses an extra entitlement" "unexpected entitlement" "${bad}"

    bad="${dir}/unentitled"
    cp -R "${good}" "${bad}"
    sign_copy "${bad}/bin/parbake"
    expect_problem "verify_root refuses a missing virtualization entitlement" "missing com.apple" "${bad}"

    bad="${dir}/false-entitlement"
    cp -R "${good}" "${bad}"
    sign_copy "${bad}/bin/parbake" "${dir}/false.plist"
    expect_problem "verify_root refuses the virtualization entitlement set to false" "is not true" "${bad}"

    bad="${dir}/setuid"
    cp -R "${good}" "${bad}"
    chmod 4755 "${bad}/bin/parbake"
    expect_problem "verify_root refuses a setuid file" "setuid, setgid or world-writable" "${bad}"

    bad="${dir}/world-writable"
    cp -R "${good}" "${bad}"
    chmod 0666 "${bad}/config.toml"
    expect_problem "verify_root refuses a world-writable file" "config.toml" "${bad}"

    bad="${dir}/symlink"
    cp -R "${good}" "${bad}"
    ln -s /usr/bin "${bad}/escape"
    expect_problem "verify_root refuses a symlink" "symlink: ${bad}/escape" "${bad}"

    bad="${dir}/symlink-binary"
    cp -R "${good}" "${bad}"
    rm "${bad}/bin/parbake-agent"
    ln -s parbake "${bad}/bin/parbake-agent"
    expect_problem "verify_root refuses a symlinked binary" "symlink: ${bad}/bin/parbake-agent" "${bad}"

    bad="${dir}/not-executable"
    cp -R "${good}" "${bad}"
    chmod 0644 "${bad}/bin/parbake-agent"
    expect_problem "verify_root refuses a binary without the execute bit" "not executable" "${bad}"

    bad="${dir}/script-binary"
    cp -R "${good}" "${bad}"
    printf '#!/bin/sh\n' >"${bad}/bin/parbake-agent"
    expect_problem "verify_root refuses a binary that is not Mach-O" "not a Mach-O" "${bad}"

    bad="${dir}/quarantine"
    cp -R "${good}" "${bad}"
    xattr -w com.apple.quarantine "0081;00000000;test;" "${bad}/bin/parbake"
    expect_problem "verify_root refuses a quarantined file" "quarantine" "${bad}"

    mkdir -p "${dir}/empty"
    expect_problem "verify_root refuses a root without Mach-O files" "no Mach-O" "${dir}/empty"

    PKG_BASE="${dir}/pkg"
    mkdir -p "${PKG_BASE}"
    cp -R "${good}" "${PKG_BASE}/root"
    expect_fail "verify refuses a root whose parbake prints no version" verify
    if [[ ! -e "${PKG_BASE}/verified" ]]; then
        pass "verify writes no stamp on failure"
    else
        fail "verify wrote a stamp for a failing root"
    fi
    self_test_verify_stamp "${dir}" "${ent}"
}

# verify on a root of signed Mach-O stubs that print a version: it passes and writes the stamp.
self_test_verify_stamp() {
    local dir="$1/stamp" ent="$2" src name
    if ! command -v cc >/dev/null 2>&1; then
        printf 'self-test skipped: verify success path, cc is unavailable\n'
        return
    fi
    mkdir -p "${dir}"
    printf '#include <stdio.h>\nint main(void) { puts("0.1.0"); return 0; }\n' >"${dir}/v.c"
    src="${dir}/version-stub"
    if ! /usr/bin/cc -o "${src}" "${dir}/v.c" >/dev/null 2>&1; then
        printf 'self-test skipped: verify success path, cc cannot build the stub\n'
        return
    fi
    PKG_BASE="${dir}/pkg"
    sign_copy "${PKG_BASE}/root/bin/container-runtime-macos" "${ent}" "${src}"
    sign_copy "${PKG_BASE}/root/bin/parbake" "${ent}" "${src}"
    sign_copy "${PKG_BASE}/root/bin/parbake-agent" "" "${src}"
    cp "${REPO_ROOT}/config.toml" "${PKG_BASE}/root/config.toml"
    name="$(verify 2>&1)" || fail "verify fails on signed stubs: ${name}"
    if [[ "$(cat "${PKG_BASE}/verified" 2>/dev/null)" == "0.1.0" && "${name}" == "verified "* ]]; then
        pass "verify succeeds on signed stubs and writes the stamp"
    else
        fail "verify success path: stamp \"$(cat "${PKG_BASE}/verified" 2>/dev/null)\", output ${name}"
    fi
}

# create refuses a missing, stale or mismatched stamp, and an unsafe archive.
self_test_create() {
    local dir="$1/create" root="$1/create/root" stamp="$1/create/verified" stub="$1/create/stub"
    mkdir -p "${root}/bin" "${stub}"
    printf 'x' >"${root}/bin/tool"
    printf '#!/bin/sh\ntouch "%s/ran"\n' "${dir}" >"${stub}/ocx"
    chmod 0755 "${stub}/ocx"
    PKG_BASE="${dir}"
    PATH="${stub}:${PATH}" expect_fail "create without a stamp fails" create 1.2.3
    if [[ ! -e "${dir}/ran" ]]; then
        pass "create runs nothing before the stamp check"
    else
        fail "create ran ocx without a stamp"
    fi
    expect_fail "create refuses a missing stamp" check_stamp "${stamp}" "${root}" 1.2.3
    printf '1.2.3\n' >"${stamp}"
    expect_code "create accepts a fresh stamp" 0 check_stamp "${stamp}" "${root}" 1.2.3
    PATH="${stub}:${PATH}" expect_fail "create fails when ocx writes no archive" create 1.2.3
    rm -f "${dir}/ran"
    PATH="${stub}:${PATH}" expect_message "create refuses a stamp of another version" "holds \"1.2.3\", want \"1.2.4\"" create 1.2.4
    if [[ ! -e "${dir}/ran" ]]; then
        pass "create runs no ocx for a stamp of another version"
    else
        fail "create ran ocx for a stamp of another version"
    fi
    sleep 1
    printf 'y' >"${root}/bin/tool"
    PATH="${stub}:${PATH}" expect_message "create refuses a stamp older than the root" "is newer than the stamp" create 1.2.3
    if [[ ! -e "${dir}/ran" ]]; then
        pass "create runs no ocx for a stale stamp"
    else
        fail "create ran ocx for a stale stamp"
    fi
    expect_fail "create refuses a stamp older than the root" check_stamp "${stamp}" "${root}" 1.2.3
    mkdir -p "${dir}/tar/inner"
    printf 'x' >"${dir}/tar/inner/file"
    tar -cf "${dir}/good.tar" -C "${dir}/tar" inner
    tar -cPf "${dir}/absolute.tar" "${dir}/tar/inner/file" 2>/dev/null
    tar -cf "${dir}/dotdot.tar" -C "${dir}/tar/inner" ../inner/file
    expect_code "create accepts a plain archive" 0 check_archive "${dir}/good.tar"
    expect_fail "create refuses an absolute archive member" check_archive "${dir}/absolute.tar"
    expect_fail "create refuses a .. archive member" check_archive "${dir}/dotdot.tar"
}

# fixture_git ARGS...: run git for the fixture fork only, with its own identity and no signing.
fixture_git() {
    git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"
}

# make_fork DIR: a fork repository with the tags ocx-1.6.1_01 (annotated, builds the fixture pin)
# and ocx-1.6.1_02 (lightweight, builds another revision).
make_fork() {
    local dir="$1" pin
    pin="$(fork_pin "${FIXTURES}/Package.resolved" | tail -n 1)"
    git init -q "${dir}"
    mkdir -p "${dir}/ocx"
    printf '%s\n' "${pin}" >"${dir}/ocx/source-revision"
    fixture_git -C "${dir}" add ocx/source-revision
    fixture_git -C "${dir}" commit -q -m "pinned revision"
    fixture_git -C "${dir}" tag -a -m "ocx 1.6.1_01" ocx-1.6.1_01
    printf '%s\n' "ffffffffffffffffffffffffffffffffffffffff" >"${dir}/ocx/source-revision"
    fixture_git -C "${dir}" commit -q -a -m "other revision"
    fixture_git -C "${dir}" tag ocx-1.6.1_02
    fixture_git -C "${dir}" rm -q ocx/source-revision
    fixture_git -C "${dir}" commit -q -m "no revision file"
    fixture_git -C "${dir}" tag ocx-1.6.1_04
}

# pair against a fixture fork repository, with no network.
self_test_pair() {
    local dir="$1/pair" fork="$1/pair/fork" tag_file="$1/pair/container.tag" out got
    mkdir -p "${dir}"
    PKG_BASE="${dir}/pkg"
    CONTAINER_TAG_FILE="${tag_file}"
    PACKAGE_RESOLVED="${FIXTURES}/Package.resolved"
    make_fork "${fork}"
    out="$(pair 2>&1)" || fail "pair fails without a tag file: ${out}"
    if [[ "${out}" == "no container tag, pairing skipped" ]]; then
        pass "pair skips when the tag file is absent"
    else
        fail "skip message: ${out}"
    fi
    export PACKAGE_PAIR_LOCATION="file://${fork}"
    printf '1.6.1_01\n' >"${tag_file}"
    expect_code "pair passes when the tag builds the pinned revision" 0 pair
    printf '1.6.1_02\n' >"${tag_file}"
    expect_message "pair fails and names both revisions on a mismatch" \
        "container tag ocx-1.6.1_02 builds ffffffffffffffffffffffffffffffffffffffff, Package.resolved pins 0f8245481903d4db3fe701bbf0750924b450bc4d" pair
    printf '1.6.1_03\n' >"${tag_file}"
    expect_message "pair fails on a missing tag" "container tag ocx-1.6.1_03 not found" pair
    printf '1.6.1_04\n' >"${tag_file}"
    expect_message "pair fails on a tag without ocx/source-revision" "container tag ocx-1.6.1_04 has no ocx/source-revision" pair
    printf '1.6.1_01\r\n' >"${tag_file}"
    expect_code "pair accepts a CRLF tag file, as the workflow does" 0 pair
    printf '1.6.1_01  \n' >"${tag_file}"
    expect_code "pair accepts trailing spaces in the tag file, as the workflow does" 0 pair
    printf '1.6.1_01\n' >"${tag_file}"
    PACKAGE_PAIR_LOCATION="https://github.com/extra-code/container" expect_message \
        "pair refuses a PACKAGE_PAIR_LOCATION that is not a file:// URL" "must be a file:// URL" pair
    PACKAGE_PAIR_LOCATION="file://${dir}/absent" expect_message "pair names the git error when the fetch fails" "not found: " pair
    for got in "" "1.6.1" "v1.6.1_01" "1.6.1_1" "1.6.1_001" "1.6.1_01 x" "1.6_01"; do
        printf '%s\n' "${got}" >"${tag_file}"
        expect_message "pair rejects the tag \"${got}\"" "invalid container tag" pair
    done
    printf '1.6.1_01\n1.6.1_02\n' >"${tag_file}"
    expect_message "pair rejects a two-line tag file" "invalid container tag" pair
    printf '1.6.1_01\n' >"${tag_file}"
    PACKAGE_RESOLVED="${FIXTURES}/Package.resolved.nofork"
    expect_message "pair needs the fork pin" "fork pin not found" pair
    sed 's#https://github.com/extra-code/container.git#https://example.com/extra-code/container.git#' \
        "${FIXTURES}/Package.resolved" >"${dir}/other-host"
    PACKAGE_RESOLVED="${dir}/other-host"
    expect_message "pair validates the pin location even with an override" "invalid fork pin" pair
    unset PACKAGE_PAIR_LOCATION
    PACKAGE_RESOLVED="${REPO_ROOT}/Package.resolved"
    CONTAINER_TAG_FILE="${REPO_ROOT}/packaging/container.tag"
    if [[ -z "$(find "${PKG_BASE}" -name 'pair.*' 2>/dev/null)" ]]; then
        pass "pair removes its temp git directory"
    else
        fail "pair left a temp git directory"
    fi
}

# the rm guard.
self_test_rm_guard() {
    local base="$1/.build/package" outside="$1/outside"
    PKG_BASE="${base}"
    mkdir -p "${base}/inside/deep" "${outside}"
    expect_fail "rm guard refuses an empty path" safe_rm ""
    expect_fail "rm guard refuses /" safe_rm "/"
    expect_fail "rm guard refuses a path outside the package base" safe_rm "${outside}"
    expect_fail "rm guard refuses the package base itself" safe_rm "${base}"
    expect_fail "rm guard refuses .. out of the package base" safe_rm "${base}/../outside"
    ln -s "${outside}" "${base}/link"
    expect_fail "rm guard refuses a symlink leaving the package base" safe_rm "${base}/link/x"
    if [[ -d "${outside}" ]]; then
        pass "the refused paths are still there"
    else
        fail "a refused path was removed"
    fi
    expect_code "rm guard accepts a path inside" 0 safe_rm "${base}/inside"
    if [[ ! -e "${base}/inside" ]]; then
        pass "the accepted path is removed"
    else
        fail "the accepted path is still there"
    fi
}

# repo_state: what the self-test must leave alone: the package base listing and the untracked and
# ignored files, plus changes to the tracked files nothing else writes (scripts, packaging,
# config.toml) and the release-assets listing. The Swift build, SwiftPM, Finder and other
# worktrees write the excluded paths concurrently with task check.
repo_state() {
    (
        cd "${REPO_ROOT}"
        ls -lR .build/package 2>/dev/null || true
        ls -lR .build/release-assets 2>/dev/null || true
        git diff --name-only -- scripts packaging config.toml
        git status --porcelain --ignored --untracked-files=all | awk '
            /^(\?\?|!!) / {
                path = substr($0, 4)
                if (path ~ /^\.build(\/|$)/ || path ~ /^\.swiftpm(\/|$)/ || path ~ /^\.agents\/worktrees(\/|$)/ || path ~ /(^|\/)\.DS_Store$/) next
                print
            }'
    )
}

self_test() {
    local before after
    WORK="$(mktemp -d)"
    trap 'rm -rf "${WORK}"' EXIT
    before="$(repo_state)"
    self_test_usage
    self_test_metadata
    self_test_metadata_shape
    self_test_metadata_binaries
    self_test_pin "${WORK}"
    self_test_stage "${WORK}"
    self_test_parsing
    self_test_verify "${WORK}"
    self_test_create "${WORK}"
    self_test_pair "${WORK}"
    self_test_rm_guard "${WORK}"
    after="$(repo_state)"
    if [[ "${before}" == "${after}" ]]; then
        pass "the self-test leaves .build/package and the untracked files as they were"
    else
        fail "the self-test changed .build/package or the untracked files"
    fi
    if [[ "${STATUS}" -eq 0 ]]; then
        printf 'package.sh self-test passed\n'
    fi
    return "${STATUS}"
}

main() {
    case "${1:-}" in
        --self-test) self_test ;;
        -h | --help) usage ;;
        verify | pair)
            [[ $# -eq 1 ]] || usage_error "$1 takes no argument" || return 2
            "$1"
            ;;
        stage | create | all)
            [[ $# -eq 2 ]] || usage_error "$1 needs VERSION" || return 2
            valid_version "$2" || return 2
            "$1" "$2"
            ;;
        "") usage_error "no subcommand" ;;
        *) usage_error "unknown subcommand \"$1\"" ;;
    esac
}

main "$@"
