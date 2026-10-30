#!/bin/bash
# SPDX-FileCopyrightText: 2026 Christian Semmelmann
# SPDX-License-Identifier: Apache-2.0

# --- usage ---
# Runs the published Parbake packages end to end in an isolated sandbox: verify, install, boot a
# macOS guest and run a command in it. The sandbox lives under PKG_E2E_ROOT and is removed at the end.
#
# Usage:
#   package-e2e.sh run [--candidate VERSION] [--keep] [--recover]
#                               Run the checks. --candidate pushes .build/package/parbake-VERSION.tar.xz
#                               (and PKG_E2E_CONTAINER_ARCHIVE when set) to a local registry and tests
#                               those instead of the published packages. --keep leaves the sandbox in
#                               place. --recover stops an apiserver a killed run left under
#                               PKG_E2E_ROOT, restarts the stock services and removes stale sandboxes.
#   package-e2e.sh --self-test  Offline checks of the script.
#   package-e2e.sh -h | --help  Print this usage.
#
# Environment (each optional):
#   PKG_E2E_CONTAINER_REF      Default ghcr.io/extra-code/container:<packaging/container.tag>
#   PKG_E2E_PARBAKE_REF        Default ghcr.io/extra-code/parbake:<first "## vX.Y.Z" of CHANGELOG.md>
#   PKG_E2E_CONTAINER_ARCHIVE  Default unset. Candidate mode: a container .tar.xz archive to push; its
#                              -metadata.json must sit beside it; made absolute, a leading - is refused
#   PKG_E2E_RESTORE_IMAGE      Default unset (parbake picks the latest). A file or an https:// URL
#   PKG_E2E_MIN_FREE_GB        Default 60. Free space the preflight demands under home
#   PKG_E2E_RUN_TIMEOUT        Default 900. Seconds to wait for the container to run
#   PKG_E2E_TOTAL_TIMEOUT      Default 5400. Ceiling in seconds for the whole run
#   PKG_E2E_OCX_VERSION        Default 0.6.5. The ocx version the preflight requires
#   PKG_E2E_ROOT               Default ~/.parbake-e2e. Parent of sandboxes, receipts and the lock; an
#                              existing directory must be empty or hold the .parbake-e2e-root marker
#   PKG_E2E_ATTENDED           Default unset. 1 allows a run without a TTY
#
# Attended guard: run refuses with exit 3 when stdin is not a TTY, unless PKG_E2E_ATTENDED=1. This
# is a speed bump for unattended agents, not a trust boundary.
#
# Exit codes: 0 every check passed and cleanup finished; 1 a check failed; 2 a usage error; 3 refused
# before any change; 4 cleanup failed. 129, 130, 131, 141 and 143 follow a SIGHUP, SIGINT, SIGQUIT,
# SIGPIPE and SIGTERM, after cleanup.
#
# Receipt: ROOT/receipts/<run-id>.json, schema 1. Each step carries a result of pass, fail, skip or
# warn; a warn records an unexpected but harmless outcome with its detail and does not fail the run.
#
# Residual risk: the run stops the stock container services and starts them again afterwards. A
# container that was started seconds before the stop stops with the services.
# --- end usage ---
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$0")"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONTAINER_TAG_FILE="${REPO_ROOT}/packaging/container.tag"
CHANGELOG="${REPO_ROOT}/CHANGELOG.md"
QUICKSTART="${REPO_ROOT}/docs/quickstart.md"
TROUBLESHOOTING="${REPO_ROOT}/docs/package-troubleshooting.md"

# shellcheck disable=SC2034 # constants the later steps use
{
    readonly EXIT_PASS=0 EXIT_FAIL=1 EXIT_USAGE=2 EXIT_REFUSED=3 EXIT_CLEANUP=4
    readonly EXIT_SIGHUP=129 EXIT_SIGINT=130 EXIT_SIGQUIT=131 EXIT_SIGPIPE=141 EXIT_SIGTERM=143

    # "id:name" per step; the ids are the receipt's and the output's.
    readonly STEPS=(
        E01:trust-policy E02:verify-container E03:verify-parbake E04:verify-negative
        E05:local-registry E06:install-container E07:install-parbake E08:build-root
        E09:versions E10:stop-stock E11:start-sandbox E12:create-bundle
        E13:pull-and-run E14:wait-running E15:exec-guest E16:stop-and-remove
    )
    readonly PREFLIGHTS=(P01 P02 P03 P04 P05 P06 P07 P08 P09 P10 P11)

    readonly RECEIPT_SCHEMA=1
    readonly RECEIPT_KEYS=(
        schema run_id mode started finished result refused_by exit script_commit
        host ocx packages guest steps cleanup
    )

    readonly PKG_E2E_ZOT_REF="ocx.sh/project-zot/zot:2.1.21@sha256:6dbb70bfda007910fbe004f2a5256ae5e343b81808733850d812833912b98b26"

    readonly OIDC_ISSUER="https://token.actions.githubusercontent.com"
    readonly CONTAINER_IDENTITY_PREFIX="https://github.com/extra-code/container/.github/workflows/ocx-package.yml@refs/tags/ocx-"
    readonly PARBAKE_IDENTITY_PREFIX="https://github.com/extra-code/parbake/.github/workflows/release.yml@refs/tags/v"

    # The ln -s lines of the quickstart; the run substitutes the sandbox for ~/.parbake.
    readonly LINK_BIN='ln -s ~/.parbake/container/content/bin ~/.parbake/root/bin'
    readonly LINK_LIBEXEC='ln -s ~/.parbake/container/content/libexec/container ~/.parbake/root/libexec/container'
    readonly LINK_PLUGIN='ln -s ~/.parbake/plugin/content ~/.parbake/root/libexec/container-plugins/container-runtime-macos'
}

# The text of the quickstart's heredoc into ~/.ocx/config.toml, byte for byte.
IFS= read -r -d '' TRUST_POLICY <<'EOF' || true
[[trust.policy]]
scope = "ghcr.io/extra-code/container"
signers = [
  { kind = "keyless",
    identity_regexp = "^https://github.com/extra-code/container/.github/workflows/ocx-package.yml@refs/tags/ocx-[0-9]+\\.[0-9]+\\.[0-9]+_[0-9]{2}$",
    oidc_issuer = "https://token.actions.githubusercontent.com" },
]

[[trust.policy]]
scope = "ghcr.io/extra-code/parbake"
signers = [
  { kind = "keyless",
    identity_regexp = "^https://github.com/extra-code/parbake/.github/workflows/release.yml@refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+$",
    oidc_issuer = "https://token.actions.githubusercontent.com" },
]
EOF
TRUST_POLICY="${TRUST_POLICY%$'\n'}"
readonly TRUST_POLICY

CONTAINER_TAG_RE='^[0-9]+\.[0-9]+\.[0-9]+_[0-9]{2}$'
CHANGELOG_VERSION_RE='^## v([0-9]+\.[0-9]+\.[0-9]+)$'
REF_TAG_RE='^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$'
ROOT_RE='^[A-Za-z0-9/._-]+$'
RESTORE_URL_RE='^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._/-]+$'

die() {
    printf 'package-e2e.sh: %s\n' "$*" >&2
    return 1
}

usage_error() {
    printf 'package-e2e.sh: %s\n' "$*" >&2
    printf 'usage: package-e2e.sh run [--candidate VERSION] [--keep] [--recover] | --self-test | -h\n' >&2
    return 2
}

usage() {
    sed -n '/^# --- usage ---$/,/^# --- end usage ---$/p' "${SCRIPT_PATH}" | sed '1d;$d' | sed 's/^# \{0,1\}//'
}

# validate_number NAME VALUE: VALUE is 0 or up to seven digits without a leading zero.
validate_number() {
    [[ "$2" =~ ^(0|[1-9][0-9]{0,6})$ ]] || usage_error "$1 must be a number, got \"$2\"" || return 2
}

# validate_ref NAME KIND VALUE: ghcr.io/extra-code/KIND:TAG, optionally @sha256:DIGEST.
validate_ref() {
    local name="$1" kind="$2" value="$3" repo tag
    repo="ghcr.io/extra-code/${kind}:"
    [[ "${value}" == "${repo}"* ]] || usage_error "${name} must start with ${repo}, got \"${value}\"" || return 2
    tag="${value#"${repo}"}"
    tag="${tag%%@*}"
    [[ "${tag}" =~ ${REF_TAG_RE} ]] || usage_error "${name} has an invalid tag \"${tag}\"" || return 2
    if [[ "${value}" == *@* ]]; then
        [[ "${value#*@}" =~ ^sha256:[0-9a-f]{64}$ ]] || usage_error "${name} has an invalid digest" || return 2
    fi
}

# validate_root VALUE: absolute, no "..", plain characters, not a symlink, strictly below home.
validate_root() {
    local value="$1" probe home real
    [[ "${value}" == /* ]] || usage_error "PKG_E2E_ROOT must be absolute, got \"${value}\"" || return 2
    case "${value}/" in
        *//* | */./* | */../*) usage_error "PKG_E2E_ROOT must not contain //, /./ or /../, got \"${value}\"" || return 2 ;;
    esac
    [[ "${value}" != */ ]] || usage_error "PKG_E2E_ROOT must not end in /, got \"${value}\"" || return 2
    [[ "${value}" =~ ${ROOT_RE} ]] || usage_error "PKG_E2E_ROOT has characters outside A-Za-z0-9/._-, got \"${value}\"" || return 2
    [[ ! -L "${value}" ]] || usage_error "PKG_E2E_ROOT must not be a symlink" || return 2
    probe="${value}"
    while [[ ! -d "${probe}" && "${probe}" != / ]]; do
        probe="$(dirname "${probe}")"
    done
    home="$(cd -P "${HOME}" && pwd -P)" || usage_error "cannot resolve the home directory" || return 2
    real="$(cd -P "${probe}" && pwd -P)" || usage_error "cannot resolve PKG_E2E_ROOT" || return 2
    [[ "${real}" == "${home}" || "${real}" == "${home}/"* ]] || usage_error "PKG_E2E_ROOT must lie below ${home}" || return 2
    [[ "${real}" != "${home}" || "${probe}" != "${value}" ]] || usage_error "PKG_E2E_ROOT must lie strictly below ${home}" || return 2
}

# validate_restore_image VALUE: an existing regular file, or a plain https:// URL.
validate_restore_image() {
    local value="$1"
    if [[ "${value}" == https://* ]]; then
        [[ "${value}" =~ ${RESTORE_URL_RE} ]] || usage_error "PKG_E2E_RESTORE_IMAGE is not a plain https URL" || return 2
    else
        [[ "${value}" != *://* && -f "${value}" ]] || usage_error "PKG_E2E_RESTORE_IMAGE is neither a regular file nor an https URL" || return 2
    fi
}

# validate_archive VALUE: a regular file, not a URL, not an option; sets PKG_E2E_CONTAINER_ARCHIVE to its absolute path.
validate_archive() {
    local dir
    [[ "$1" != -* ]] || usage_error "PKG_E2E_CONTAINER_ARCHIVE must not start with -" || return 2
    [[ "$1" != *://* && -f "$1" ]] || usage_error "PKG_E2E_CONTAINER_ARCHIVE must be a regular file" || return 2
    dir="$(cd -P "$(dirname "$1")" && pwd -P)" || usage_error "cannot resolve PKG_E2E_CONTAINER_ARCHIVE" || return 2
    PKG_E2E_CONTAINER_ARCHIVE="${dir}/$(basename "$1")"
}

# validate_candidate_files: the candidate archives and their metadata exist (candidate mode only).
validate_candidate_files() {
    local archive="${PKG_E2E_CONTAINER_ARCHIVE:-}"
    [[ "${MODE}" == candidate ]] || return 0
    [[ -f "${PACKAGE_DIR}/parbake-${CANDIDATE_VERSION}.tar.xz" && -f "${PACKAGE_DIR}/parbake-${CANDIDATE_VERSION}-metadata.json" ]] ||
        usage_error "${PACKAGE_DIR}/parbake-${CANDIDATE_VERSION}.tar.xz or its -metadata.json is missing; run: task package VERSION=${CANDIDATE_VERSION}" || return 2
    [[ -z "${archive}" ]] && return 0
    [[ "${archive}" == *.tar.xz && -f "${archive%.tar.xz}-metadata.json" ]] ||
        usage_error "PKG_E2E_CONTAINER_ARCHIVE must end in .tar.xz and have a -metadata.json beside it" || return 2
}

# default_container_ref: ghcr.io/extra-code/container:<packaging/container.tag>.
default_container_ref() {
    local tag
    [[ -f "${CONTAINER_TAG_FILE}" ]] || usage_error "packaging/container.tag is missing" || return 2
    tag="$(tr -d '[:space:]' <"${CONTAINER_TAG_FILE}")"
    [[ "${tag}" =~ ${CONTAINER_TAG_RE} ]] || usage_error "invalid container tag \"${tag}\"" || return 2
    printf 'ghcr.io/extra-code/container:%s\n' "${tag}"
}

# default_parbake_ref: ghcr.io/extra-code/parbake:<first CHANGELOG.md release>.
default_parbake_ref() {
    local line
    while IFS= read -r line; do
        if [[ "${line}" =~ ${CHANGELOG_VERSION_RE} ]]; then
            printf 'ghcr.io/extra-code/parbake:%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <"${CHANGELOG}"
    usage_error "no release heading in CHANGELOG.md"
}

# validate_params MODE: every PKG_E2E_* value, before anything else runs. MODE is published or candidate.
validate_params() {
    local mode="$1" ref
    if [[ "${mode}" == candidate ]]; then
        [[ -z "${PKG_E2E_CONTAINER_REF:-}" && -z "${PKG_E2E_PARBAKE_REF:-}" ]] ||
            usage_error "PKG_E2E_CONTAINER_REF and PKG_E2E_PARBAKE_REF are refused in candidate mode" || return 2
    fi
    ref="${PKG_E2E_CONTAINER_REF:-}"
    [[ -n "${ref}" ]] || ref="$(default_container_ref)" || return 2
    validate_ref PKG_E2E_CONTAINER_REF container "${ref}" || return 2
    CONTAINER_REF="${ref}"
    ref="${PKG_E2E_PARBAKE_REF:-}"
    [[ -n "${ref}" ]] || ref="$(default_parbake_ref)" || return 2
    validate_ref PKG_E2E_PARBAKE_REF parbake "${ref}" || return 2
    PARBAKE_REF="${ref}"
    [[ -z "${PKG_E2E_CONTAINER_ARCHIVE:-}" ]] || validate_archive "${PKG_E2E_CONTAINER_ARCHIVE}" || return 2
    [[ -z "${PKG_E2E_RESTORE_IMAGE:-}" ]] || validate_restore_image "${PKG_E2E_RESTORE_IMAGE}" || return 2
    validate_number PKG_E2E_MIN_FREE_GB "${PKG_E2E_MIN_FREE_GB:-60}" || return 2
    validate_number PKG_E2E_RUN_TIMEOUT "${PKG_E2E_RUN_TIMEOUT:-900}" || return 2
    validate_number PKG_E2E_TOTAL_TIMEOUT "${PKG_E2E_TOTAL_TIMEOUT:-5400}" || return 2
    [[ "${PKG_E2E_OCX_VERSION:-0.6.5}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage_error "PKG_E2E_OCX_VERSION is not X.Y.Z" || return 2
    validate_root "${PKG_E2E_ROOT:-${HOME}/.parbake-e2e}" || return 2
}

# --- run state -------------------------------------------------------------------------------

readonly STOCK_PROGRAM="/usr/local/bin/container-apiserver"
readonly APISERVER_LABEL="com.apple.container.apiserver"
readonly KEYCHAIN_ACCOUNT="ci"
readonly KEYCHAIN_GUEST_SERVICE="container-runtime-macos.guest"
readonly RUN_ID_RE='^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$'
readonly KEYCHAIN_SERVICE_RE='^container-runtime-macos\.e2e\.[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$'
readonly NAME_RE='^[A-Za-z0-9][A-Za-z0-9_.-]*$'

CONTAINER_REF=""
PARBAKE_REF=""
MODE=published
CANDIDATE_VERSION=""
KEEP=0
RECOVER=0
ROOT=""
RUN_ID=""
S=""
RECEIPT=""
STARTED=""
KEYCHAIN_SERVICE=""
KEYCHAIN_OWNED=0
ZOT_PID=""
ZOT_BIN=""
ZOT_PORT=""
CONTAINER_PKG_REF=""
PARBAKE_PKG_REF=""
CONTAINER_DIGEST=""
PARBAKE_DIGEST=""
CONTAINER_VERIFIED=null
PARBAKE_VERIFIED=null
GUEST_MACOS=""
DEADLINE=0
TIMED_PID=""
TIMED_LIMIT=step
TIMED_HINT_AFTER=0
TIMED_HINT=""
STEP_DETAIL=""
STEP_SKIP=0
STEP_WARN=0
CAP_RC=0
CAP_OUT=""
CAP_ERR=""
ZOT_CHOSEN=""
REFUSED=0
REFUSED_BY=""
LOCK_HELD=0
CLEANED=0
RESULT=fail
FINAL_STATUS=1
CL_CONTAINERS=null
CL_STOCK=null
CL_KEYCHAIN=null
CL_ZOT=null
CL_SANDBOX=null
STEP_JSON=()

E2E_OCX=""
E2E_TASK=""

# selftest_hooks_valid: the self-test hooks are honoured only when _PKG_E2E_SELFTEST_NONCEFILE is a
# file the user owns under the system temp directory and holds _PKG_E2E_SELFTEST_NONCE. A real run
# never has one, so a stray _PKG_E2E_SELFTEST_BIN cannot swap the tools for stubs.
selftest_hooks_valid() {
    local file="${_PKG_E2E_SELFTEST_NONCEFILE:-}" nonce="${_PKG_E2E_SELFTEST_NONCE:-}" tmp dir
    [[ "${nonce}" =~ ^[0-9a-f]{32}$ && "${file}" == /* && -f "${file}" && ! -L "${file}" && -O "${file}" ]] || return 1
    tmp="$(cd -P "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" || return 1
    dir="$(cd -P "$(dirname "${file}")" 2>/dev/null && pwd -P)" || return 1
    [[ "${dir}/" == "${tmp%/}/"* ]] || return 1
    [[ "$(<"${file}")" == "${nonce}" ]]
}

# hygiene: no inherited OCX_* or DOCKER_CONFIG, no self-test hook without a valid nonce, a fixed PATH,
# owner-only files.
hygiene() {
    local name ocx_dir="" hooks=0
    E2E_OCX="$(command -v ocx 2>/dev/null || true)"
    E2E_TASK="$(command -v task 2>/dev/null || true)"
    ! selftest_hooks_valid || hooks=1
    while IFS= read -r name; do
        case "${name}" in
            OCX_* | DOCKER_CONFIG) unset "${name}" ;;
            _PKG_E2E_SELFTEST_*) [[ "${hooks}" == 1 ]] || unset "${name}" ;;
        esac
    done < <(compgen -e)
    [[ -z "${E2E_OCX}" ]] || ocx_dir="$(dirname "${E2E_OCX}")"
    PATH="/usr/bin:/bin:/usr/sbin:/sbin${ocx_dir:+:${ocx_dir}}"
    export PATH
    umask 077
}

# init_tools: every external tool the run uses is named here. The self-test points them at stubs
# through _PKG_E2E_SELFTEST_BIN, honoured only with a valid nonce.
init_tools() {
    local bin=""
    T_OCX="${E2E_OCX:-ocx}"
    T_SSH_KEYGEN=/usr/bin/ssh-keygen T_SECURITY=/usr/bin/security T_LAUNCHCTL=/bin/launchctl T_PLUTIL=/usr/bin/plutil
    T_LSOF=/usr/sbin/lsof T_SYSCTL=/usr/sbin/sysctl T_SW_VERS=/usr/bin/sw_vers T_DF=/bin/df T_UNAME=/usr/bin/uname
    T_PS=/bin/ps T_CURL=/usr/bin/curl
    STOCK_CLI="/usr/local/bin/container"
    PACKAGE_DIR="${REPO_ROOT}/.build/package"
    STOCK_WAIT=60 STOP_WAIT=30 POLL_INTERVAL=1 ZOT_WAIT=20 LS_INTERVAL=5 KILL_GRACE=10 CLEAN_TIMEOUT=120 SAFE_GAP=1 TIMED_POLL=0.25
    ! selftest_hooks_valid || bin="${_PKG_E2E_SELFTEST_BIN:-}"
    if [[ -n "${bin}" && "${bin}" == /* && -d "${bin}" ]]; then
        T_OCX="${bin}/ocx"
        T_SSH_KEYGEN="${bin}/ssh-keygen"
        T_SECURITY="${bin}/security"
        T_LAUNCHCTL="${bin}/launchctl"
        T_LSOF="${bin}/lsof"
        T_SYSCTL="${bin}/sysctl"
        T_SW_VERS="${bin}/sw_vers"
        T_DF="${bin}/df"
        T_UNAME="${bin}/uname"
        T_PS="${bin}/ps"
        T_CURL="${bin}/curl"
        PACKAGE_DIR="${_PKG_E2E_SELFTEST_PKGDIR:-${PACKAGE_DIR}}"
        ZOT_WAIT=3
        LS_INTERVAL=0.2
        STOCK_CLI="${bin}/stock-container"
        STOCK_WAIT=3
        STOP_WAIT=3
        POLL_INTERVAL=0.2
        KILL_GRACE=2
        CLEAN_TIMEOUT=2
        SAFE_GAP=0.2
        TIMED_POLL=0.05
    fi
}

# json_str STRING: STRING as a JSON string, with the home directory written as ~ where it starts a path
# ($HOME/ or the whole string).
json_str() {
    local s="$1" tilde="~" home="${HOME}/"
    s="$(printf '%s' "${s}" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')"
    if [[ "${#HOME}" -ge 2 ]]; then
        # A loop, not ${s//pat/rep}: bash 3.2 mangles a quoted pattern with a replacement holding ~.
        while [[ "${s}" == *"${home}"* ]]; do
            s="${s%%"${home}"*}${tilde}/${s#*"${home}"}"
        done
        [[ "${s}" != "${HOME}" ]] || s="${tilde}"
    fi
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "${s}"
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# filter_msg: stdin as one short line: no line that could carry a credential or key, at most six
# lines, joined with " | ", cut to 400 bytes without leaving a partial UTF-8 sequence (iconv -c drops it).
filter_msg() {
    local text
    text="$({ LC_ALL=C grep -Eiv 'authorization|bearer|token|password|secret|PRIVATE KEY' || true; } | LC_ALL=C sed '/^[[:space:]]*$/d' | head -n 6 | paste -sd '|' - | LC_ALL=C sed 's/|/ | /g' | head -c 400)" || true
    printf '%s' "${text}" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true
}

# record_step ID NAME RESULT SECONDS DETAIL: one entry of the receipt's steps.
record_step() {
    local detail
    detail="$(filter_msg <<<"$5")"
    STEP_JSON+=("{\"id\": $(json_str "$1"), \"name\": $(json_str "$2"), \"result\": $(json_str "$3"), \"seconds\": $4, \"detail\": $(json_str "${detail}")}")
}

# json_or_null STRING: STRING as a JSON string, or null when it is empty.
json_or_null() {
    if [[ -n "$1" ]]; then json_str "$1"; else printf 'null'; fi
}

# major_minor VERSION: the first two numbers of VERSION.
major_minor() {
    local major minor rest
    IFS=. read -r major minor rest <<<"$1"
    printf '%s.%s' "${major}" "${minor:-0}"
}

# script_commit: the HEAD commit of the checkout, "-dirty" when the tree is not clean, or unknown.
script_commit() {
    local commit
    commit="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null)" || {
        printf 'unknown'
        return 0
    }
    if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain 2>/dev/null)" ]]; then
        commit="${commit}-dirty"
    fi
    printf '%s' "${commit}"
}

# receipt_package REF DIGEST VERIFIED: one entry of the receipt's packages.
receipt_package() {
    printf '{ "ref": %s, "digest": %s, "verified": %s }' "$(json_or_null "$1")" "$(json_or_null "$2")" "$3"
}

# write_receipt: ROOT/receipts/RUN_ID.json, mode 600, through a temporary file.
write_receipt() {
    local dir="${ROOT}/receipts" tmp refused_by=null steps="" item sep="" macos arch ocx_version guest=null
    RECEIPT="${dir}/${RUN_ID}.json"
    tmp="${dir}/.${RUN_ID}.tmp"
    [[ -z "${REFUSED_BY}" ]] || refused_by="$(json_str "${REFUSED_BY}")"
    for item in ${STEP_JSON[@]+"${STEP_JSON[@]}"}; do
        steps="${steps}${sep}${item}"
        sep=", "
    done
    macos="$("${T_SW_VERS}" -productVersion 2>/dev/null)" || macos=""
    arch="$("${T_UNAME}" -m 2>/dev/null)" || arch=""
    ocx_version="$("${T_OCX}" version 2>/dev/null | tr -d '[:space:]')" || ocx_version=""
    [[ -z "${macos}" ]] || macos="$(major_minor "${macos}")"
    [[ -z "${GUEST_MACOS}" ]] || guest="$(json_str "${GUEST_MACOS}")"
    mkdir -p "${dir}" && chmod 700 "${dir}" || die "cannot create ${dir}" || return 1
    {
        printf '{\n'
        printf '  "schema": %s,\n' "${RECEIPT_SCHEMA}"
        printf '  "run_id": %s,\n' "$(json_str "${RUN_ID}")"
        printf '  "mode": %s,\n' "$(json_str "${MODE}")"
        printf '  "started": %s, "finished": %s,\n' "$(json_str "${STARTED}")" "$(json_str "$(now)")"
        printf '  "result": %s,\n' "$(json_str "${RESULT}")"
        printf '  "refused_by": %s,\n' "${refused_by}"
        printf '  "exit": %s,\n' "${FINAL_STATUS}"
        printf '  "script_commit": %s,\n' "$(json_str "$(script_commit)")"
        printf '  "host": { "macos": %s, "arch": %s },\n' "$(json_or_null "${macos}")" "$(json_or_null "${arch}")"
        printf '  "ocx": %s,\n' "$(json_or_null "${ocx_version}")"
        printf '  "packages": {\n    "container": %s,\n    "parbake": %s\n  },\n' \
            "$(receipt_package "${CONTAINER_PKG_REF}" "${CONTAINER_DIGEST}" "${CONTAINER_VERIFIED}")" \
            "$(receipt_package "${PARBAKE_PKG_REF}" "${PARBAKE_DIGEST}" "${PARBAKE_VERIFIED}")"
        printf '  "guest": { "macos": %s },\n' "${guest}"
        printf '  "steps": [%s],\n' "${steps}"
        printf '  "cleanup": { "containers_removed": %s, "stock_restored": %s, "keychain_item_removed": %s, "zot_stopped": %s, "sandbox_removed": %s }\n' \
            "${CL_CONTAINERS}" "${CL_STOCK}" "${CL_KEYCHAIN}" "${CL_ZOT}" "${CL_SANDBOX}"
        printf '}\n'
    } >"${tmp}" || die "cannot write the receipt" || return 1
    chmod 600 "${tmp}" && mv -f "${tmp}" "${RECEIPT}" || die "cannot write the receipt" || return 1
}

# refuse ID MESSAGE: records a refusal by preflight ID; always returns 1.
refuse() {
    REFUSED=1
    REFUSED_BY="$1"
    die "refused by $1: $2"
}

# --- host state ------------------------------------------------------------------------------

# apiserver_field KEY: a field (program or state) of the launchd apiserver service, or nothing.
apiserver_field() {
    "${T_LAUNCHCTL}" print "gui/$(id -u)/${APISERVER_LABEL}" 2>/dev/null |
        awk -v key="$1" '$1 == key && $2 == "=" { print $3; exit }' || true
}

apiserver_program() { apiserver_field program; }

stock_running() { [[ "$(apiserver_program)" == "${STOCK_PROGRAM}" ]]; }

sandbox_apiserver_running() {
    local program
    [[ -n "${S}" ]] || return 1
    program="$(apiserver_program)"
    [[ "${program}" == "${S}/"* ]]
}

# no_apiserver_under_root: twice, SAFE_GAP apart, launchctl answers and no apiserver program lies under
# ROOT. An error other than "service not found" (113) counts as unsafe, so a flaky launchctl never
# lets a sandbox be removed while its services may still run.
no_apiserver_under_root() {
    local attempt out rc program
    for attempt in 1 2; do
        rc=0
        out="$("${T_LAUNCHCTL}" print "gui/$(id -u)/${APISERVER_LABEL}" 2>/dev/null)" || rc=$?
        if [[ "${rc}" -eq 0 ]]; then
            program="$(awk '$1 == "program" && $2 == "=" { print $3; exit }' <<<"${out}")"
            [[ "${program}" != "${ROOT}/"* ]] || return 1
        elif [[ "${rc}" -ne 113 ]]; then
            return 1
        fi
        [[ "${attempt}" -eq 2 ]] || sleep "${SAFE_GAP}"
    done
}

# poll_until SECONDS COMMAND...: retries COMMAND until it succeeds or SECONDS pass.
poll_until() {
    local end=$((SECONDS + $1))
    shift
    while ! "$@"; do
        [[ "${SECONDS}" -lt "${end}" ]] || return 1
        sleep "${POLL_INTERVAL}"
    done
}

# record_stock_state: S/state says whether the stock services run, right before they are stopped.
record_stock_state() {
    local ran=0
    if [[ "$(apiserver_program)" == "${STOCK_PROGRAM}" && "$(apiserver_field state)" == running ]]; then
        ran=1
    fi
    printf 'stock_ran=%s\n' "${ran}" >"${S}/state" || die "cannot write ${S}/state" || return 1
}

# --- preflight -------------------------------------------------------------------------------

p01_host() {
    local macos arch hv
    macos="$("${T_SW_VERS}" -productVersion 2>/dev/null)" || macos=""
    arch="$("${T_UNAME}" -m 2>/dev/null)" || arch=""
    hv="$("${T_SYSCTL}" -n kern.hv_vmm_present 2>/dev/null)" || hv=""
    [[ "${macos%%.*}" == 27 ]] || refuse P01 "macOS 27 is required, this host runs \"${macos}\"" || return 1
    [[ "${arch}" == arm64 ]] || refuse P01 "arm64 is required, this host is \"${arch}\"" || return 1
    [[ "${hv}" == 0 ]] || refuse P01 "the host must not be a virtual machine: kern.hv_vmm_present is \"${hv}\"" || return 1
}

p02_tools() {
    local tool version
    for tool in "${T_OCX}" "${T_SSH_KEYGEN}" "${T_SECURITY}" "${T_LAUNCHCTL}" "${T_PLUTIL}" "${T_LSOF}"; do
        command -v "${tool}" >/dev/null 2>&1 || refuse P02 "missing tool: $(basename "${tool}")" || return 1
    done
    version="$("${T_OCX}" version 2>/dev/null)" || version=""
    version="$(tr -d '[:space:]' <<<"${version}")"
    [[ "${version}" == "${PKG_E2E_OCX_VERSION:-0.6.5}" ]] ||
        refuse P02 "ocx ${PKG_E2E_OCX_VERSION:-0.6.5} is required, found \"${version}\"" || return 1
}

p03_attended() {
    [[ -t 0 || "${PKG_E2E_ATTENDED:-}" == 1 ]] ||
        refuse P03 "stdin is not a terminal; set PKG_E2E_ATTENDED=1 to run unattended" || return 1
}

p05_space() {
    local kb need free
    kb="$("${T_DF}" -Pk "${HOME}" 2>/dev/null | awk 'NR == 2 { print $4 }')" || kb=""
    [[ "${kb}" =~ ^[0-9]+$ ]] || refuse P05 "cannot read the free space under ${HOME}" || return 1
    need="${PKG_E2E_MIN_FREE_GB:-60}"
    free=$((kb / 1048576))
    [[ "${free}" -ge "${need}" ]] || refuse P05 "needs ${need} GB free under ${HOME}, ${free} GB free" || return 1
}

# p06_keychain: the login keychain is named explicitly; without a path security answers for no keychain.
p06_keychain() {
    "${T_SECURITY}" show-keychain-info "${HOME}/Library/Keychains/login.keychain-db" >/dev/null 2>&1 ||
        refuse P06 "the login keychain is locked; unlock it with: security unlock-keychain" || return 1
}

p07_no_item() {
    assert_service "${KEYCHAIN_SERVICE}" || refuse P07 "invalid keychain service \"${KEYCHAIN_SERVICE}\"" || return 1
    if "${T_SECURITY}" find-generic-password -s "${KEYCHAIN_SERVICE}" >/dev/null 2>&1; then
        refuse P07 "a keychain item exists for ${KEYCHAIN_SERVICE}" || return 1
    fi
}

p08_apiserver() {
    local program
    program="$(apiserver_program)"
    case "${program}" in
        "" | "${STOCK_PROGRAM}") ;;
        "${ROOT}/"*) refuse P08 "an apiserver of an earlier run lies under ${ROOT} (${program}); run: scripts/package-e2e.sh run --recover" || return 1 ;;
        *) refuse P08 "a foreign apiserver runs: ${program}" || return 1 ;;
    esac
}

p09_containers() {
    local list
    stock_running || return 0
    list="$("${STOCK_CLI}" ls -a --quiet 2>/dev/null)" || refuse P09 "cannot list the stock containers" || return 1
    [[ -z "${list}" ]] ||
        refuse P09 "stock containers exist ($(tr '\n' ' ' <<<"${list}")); stop and remove them with: container rm -f <id>" || return 1
}

# resolve_ref REF: REF resolves for darwin/arm64 only. A scratch OCX_HOME keeps the user's own home
# untouched; the lookup is read-only.
resolve_ref() {
    local ref="${1%%@*}" out tmp rc=0
    tmp="$(mktemp -d)" || return 1
    mkdir -p "${tmp}/docker"
    out="$(env OCX_HOME="${tmp}/home" OCX_NO_CONFIG=1 OCX_NO_PROJECT=1 DOCKER_CONFIG="${tmp}/docker" OCX_NO_UPDATE_CHECK=1 \
        "${T_OCX}" --remote --format json index list --platforms "${ref}" 2>/dev/null)" || rc=1
    [[ -n "${tmp}" && "${tmp}" == */* ]] && rm -rf -- "${tmp}"
    [[ "${rc}" -eq 0 ]] || return 1
    out="$(tr -d '[:space:]' <<<"${out}")"
    [[ "${out}" == "{\"${ref}\":[\"darwin/arm64\"]}" ]]
}

# ref_tag REF: the tag of REF.
ref_tag() {
    local ref="${1%%@*}"
    printf '%s' "${ref##*:}"
}

# ref_digest REF: the digest the tag of REF resolves to, read from the registry (ocx prints none).
# ghcr.io hands out an anonymous pull token; a 127.0.0.1 registry is read over plain http.
ref_digest() {
    local ref="${1%%@*}" host rest repo tag scheme=https token="" out digest
    host="${ref%%/*}"
    rest="${ref#*/}"
    tag="${rest##*:}"
    repo="${rest%:*}"
    [[ "${host}" == 127.0.0.1:* ]] && scheme=http
    if [[ "${scheme}" == https ]]; then
        out="$("${T_CURL}" -q -fsS --max-time 30 "https://${host}/token?scope=repository:${repo}:pull")" || die "cannot get a pull token from ${host}" || return 1
        token="$("${T_PLUTIL}" -extract token raw -o - - <<<"${out}" 2>/dev/null)" || token=""
        [[ "${token}" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || die "no usable pull token from ${host}" || return 1
    fi
    # The token goes through a curl config on stdin, so it never shows in the process list.
    out="$({ [[ -z "${token}" ]] || printf 'header = "Authorization: Bearer %s"\n' "${token}"; } |
        "${T_CURL}" -q -fsSI --max-time 30 -K - \
            -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json" \
            "${scheme}://${host}/v2/${repo}/manifests/${tag}")" || die "cannot read the digest of ${ref}" || return 1
    digest="$(tr -d '\r' <<<"${out}" | awk 'tolower($1) == "docker-content-digest:" { print $2; exit }')"
    [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "no digest for ${ref}" || return 1
    printf '%s' "${digest}"
}

# resolve_published KIND REF: resolves REF, sets <KIND>_DIGEST to its digest (the one REF carries, else the registry's).
resolve_published() {
    local kind="$1" ref="$2" digest=""
    resolve_ref "${ref}" || refuse P10 "${ref} does not resolve for darwin/arm64" || return 1
    if [[ "${ref}" == *@* ]]; then
        digest="${ref#*@}"
    else
        digest="$(ref_digest "${ref}")" || refuse P10 "cannot read the digest of ${ref}" || return 1
    fi
    if [[ "${kind}" == container ]]; then CONTAINER_DIGEST="${digest}"; else PARBAKE_DIGEST="${digest}"; fi
}

# p10_references: published mode resolves both references; candidate mode resolves the published
# container only (without a container archive) and builds the Parbake reference itself.
p10_references() {
    CONTAINER_PKG_REF="${CONTAINER_REF%%@*}"
    if [[ "${MODE}" == published ]]; then
        PARBAKE_PKG_REF="${PARBAKE_REF%%@*}"
        resolve_published parbake "${PARBAKE_REF}" || return 1
    fi
    if [[ "${MODE}" == published || -z "${PKG_E2E_CONTAINER_ARCHIVE:-}" ]]; then
        resolve_published container "${CONTAINER_REF}" || return 1
    else
        CONTAINER_PKG_REF=""
    fi
}

p11_restore_image() {
    local image="${PKG_E2E_RESTORE_IMAGE:-}"
    [[ -z "${image}" || "${image}" == https://* || -f "${image}" ]] ||
        refuse P11 "PKG_E2E_RESTORE_IMAGE \"${image}\" does not exist" || return 1
}

# preflight: P01 to P11 in order (P04 is the lock, taken before it); the first failure refuses.
preflight() {
    p01_host || return 3
    p02_tools || return 3
    p03_attended || return 3
    p05_space || return 3
    p06_keychain || return 3
    p07_no_item || return 3
    p08_apiserver || return 3
    p09_containers || return 3
    p10_references || return 3
    p11_restore_image || return 3
    if "${T_SECURITY}" find-internet-password -s registry-1.docker.io >/dev/null 2>&1; then
        printf 'note: a registry-1.docker.io login exists; macOS may ask once at E13 for the new container build to read it\n'
    fi
}

# --- lock ------------------------------------------------------------------------------------

# acquire_lock: ROOT/.lock, a directory holding pid and cmd; a stale one is taken over.
acquire_lock() {
    local lock="${ROOT}/.lock" stale pid cmd
    if ! mkdir -m 700 "${lock}" 2>/dev/null; then
        pid="$(cat "${lock}/pid" 2>/dev/null || true)"
        [[ "${pid}" =~ ^[0-9]+$ ]] ||
            refuse P04 "the lock ${lock} names no holder; remove it by hand when no run is active" || return 1
        cmd="$("${T_PS}" -p "${pid}" -o command= 2>/dev/null || true)"
        [[ "${cmd}" != *package-e2e.sh* ]] || refuse P04 "another run holds the lock (PID ${pid})" || return 1
        stale="${ROOT}/.lock.stale.${RUN_ID}"
        mv "${lock}" "${stale}" 2>/dev/null || refuse P04 "another run took over the stale lock" || return 1
        # The moved directory must still name the PID judged stale; else a live run's lock was moved.
        if [[ "$(cat "${stale}/pid" 2>/dev/null || true)" != "${pid}" ]]; then
            [[ -e "${lock}" ]] || mv "${stale}" "${lock}" 2>/dev/null || true
            refuse P04 "the lock changed hands while it was judged stale" || return 1
        fi
        mkdir -m 700 "${lock}" 2>/dev/null || refuse P04 "another run took the lock" || return 1
        rm -f -- "${stale}/pid" "${stale}/cmd"
        rmdir "${stale}" 2>/dev/null || true
        printf 'package-e2e.sh: took over a stale lock (PID %s)\n' "${pid}" >&2
    fi
    LOCK_HELD=1
    printf '%s\n' "$$" >"${lock}/pid"
    printf '%s\n' "package-e2e.sh run" >"${lock}/cmd"
}

release_lock() {
    local lock="${ROOT}/.lock"
    [[ "${LOCK_HELD}" == 1 ]] || return 0
    LOCK_HELD=0
    [[ "$(cat "${lock}/pid" 2>/dev/null || true)" == "$$" ]] || return 0
    rm -f -- "${lock}/pid" "${lock}/cmd"
    rmdir "${lock}"
}

# --- sandbox ---------------------------------------------------------------------------------

new_run_id() {
    printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
}

# assert_service SERVICE: the run's keychain service, never the guest's.
assert_service() {
    [[ "$1" =~ ${KEYCHAIN_SERVICE_RE} && "$1" != "${KEYCHAIN_GUEST_SERVICE}" ]] ||
        die "refusing the keychain service \"$1\"" || return 1
}

# create_sandbox: S = ROOT/RUN_ID and its directories. Returns 3 when S exists, 1 on any other failure.
create_sandbox() {
    local dir="${ROOT}/${RUN_ID}" sub
    if ! mkdir -m 700 "${dir}" 2>/dev/null; then
        REFUSED=1
        die "the sandbox ${dir} exists or cannot be created" || return 3
    fi
    S="${dir}"
    for sub in ocx docker link root app cache bundle; do
        mkdir "${S}/${sub}" || die "cannot create ${S}/${sub}" || return 1
    done
    mkdir -m 700 "${S}/key" || die "cannot create ${S}/key" || return 1
    "${T_SSH_KEYGEN}" -q -t ed25519 -N '' -f "${S}/key/id_ed25519" >/dev/null || die "ssh-keygen failed" || return 1
    if [[ "${MODE}" == candidate ]]; then
        mkdir -m 700 "${S}/zot" || die "cannot create ${S}/zot" || return 1
    fi
}

# remove_sandbox ROOT RUN_ID SANDBOX: removes SANDBOX only when it is the directory ROOT/RUN_ID.
remove_sandbox() {
    local root="$1" id="$2" sandbox="$3" real_root real
    validate_root "${root}" >/dev/null 2>&1 || die "refusing to remove under \"${root}\"" || return 1
    [[ "${id}" =~ ${RUN_ID_RE} ]] || die "refusing to remove: malformed run id \"${id}\"" || return 1
    [[ "${sandbox}" == "${root}/${id}" ]] || die "refusing to remove \"${sandbox}\": not ${root}/${id}" || return 1
    [[ -d "${sandbox}" && ! -L "${sandbox}" ]] || die "refusing to remove \"${sandbox}\": not a plain directory" || return 1
    real_root="$(cd -P "${root}" && pwd -P)" || die "cannot resolve ${root}" || return 1
    real="$(cd -P "${sandbox}" && pwd -P)" || die "cannot resolve ${sandbox}" || return 1
    [[ "${real}" == "${real_root}/${id}" ]] || die "refusing to remove \"${sandbox}\": it resolves to ${real}" || return 1
    rm -rf -- "${sandbox}"
    [[ ! -e "${sandbox}" ]] || die "${sandbox} is still there" || return 1
}

# delete_run_keychain_item SERVICE: deletes the one item of a run's service.
delete_run_keychain_item() {
    assert_service "$1" || return 1
    bounded 30 "${T_SECURITY}" delete-generic-password -s "$1" -a "${KEYCHAIN_ACCOUNT}"
}

# --- cleanup ---------------------------------------------------------------------------------

# bounded_to OUT SECONDS COMMAND...: COMMAND with stdout in OUT, stderr discarded, killed with its
# process tree after SECONDS (status 124). Cleanup runs with INT and TERM ignored, and run_timed
# resets them for the child, so a hung command cannot block cleanup. The run's total deadline does
# not apply: cleanup runs after it ended.
bounded_to() {
    local out="$1" secs="$2" saved="${DEADLINE}" rc=0
    shift 2
    DEADLINE=$((SECONDS + secs + 5))
    run_timed "${secs}" "${out}" /dev/null "$@" || rc=$?
    DEADLINE="${saved}"
    return "${rc}"
}

bounded() {
    local secs="$1"
    shift
    bounded_to /dev/null "${secs}" "$@"
}

cleanup_containers() {
    local cli="${S}/root/bin/container" ids id rc=0
    CL_CONTAINERS=null
    sandbox_apiserver_running || return 0
    CL_CONTAINERS=false
    [[ -x "${cli}" ]] || die "the sandbox services run but ${cli} is missing" || return 1
    bounded_to "${S}/.cout" 60 "${cli}" ls -a --quiet || die "cannot list the sandbox containers" || return 1
    ids="$(<"${S}/.cout")"
    while IFS= read -r id; do
        [[ -n "${id}" ]] || continue
        if [[ "${id}" =~ ${NAME_RE} ]] && bounded 60 "${cli}" rm -f "${id}"; then
            continue
        fi
        die "cannot remove the container \"${id}\"" || rc=1
    done <<<"${ids}"
    [[ "${rc}" -eq 0 ]] || return 1
    CL_CONTAINERS=true
}

cleanup_sandbox_services() {
    local cli="${S}/root/bin/container"
    sandbox_apiserver_running || return 0
    [[ -x "${cli}" ]] || die "the sandbox services run but ${cli} is missing" || return 1
    bounded "${CLEAN_TIMEOUT}" "${cli}" system stop || die "cannot stop the sandbox services: ${cli} system stop" || return 1
    poll_until "${STOP_WAIT}" sandbox_apiserver_gone || die "the sandbox services still run" || return 1
}

sandbox_apiserver_gone() { ! sandbox_apiserver_running; }

# cleanup_stock: restarts the stock services when S/state says they ran, then records stock_ran=0 so a
# kept sandbox never triggers a second restart.
cleanup_stock() {
    CL_STOCK=null
    [[ -n "${S}" && -f "${S}/state" ]] || return 0
    grep -qx 'stock_ran=1' "${S}/state" || return 0
    CL_STOCK=false
    bounded "${CLEAN_TIMEOUT}" "${STOCK_CLI}" system start ||
        die "the stock services did not start; run by hand: ${STOCK_CLI} system start" || return 1
    poll_until "${STOCK_WAIT}" stock_running ||
        die "the stock services do not run; run by hand: ${STOCK_CLI} system start" || return 1
    CL_STOCK=true
    printf 'stock_ran=0\n' >"${S}/state" || die "cannot rewrite ${S}/state" || return 1
}

cleanup_keychain() {
    CL_KEYCHAIN=null
    [[ "${KEYCHAIN_OWNED}" == 1 ]] || return 0
    CL_KEYCHAIN=false
    if bounded 30 "${T_SECURITY}" find-generic-password -s "${KEYCHAIN_SERVICE}"; then
        delete_run_keychain_item "${KEYCHAIN_SERVICE}" ||
            die "the keychain item ${KEYCHAIN_SERVICE} is still there; delete it in Keychain Access" || return 1
    fi
    CL_KEYCHAIN=true
}

zot_alive() {
    local command
    command="$("${T_PS}" -p "${ZOT_PID}" -o command= 2>/dev/null || true)"
    [[ -n "${ZOT_BIN}" && "${command}" == *"${ZOT_BIN}"* ]]
}

zot_gone() { ! zot_alive; }

cleanup_zot() {
    CL_ZOT=null
    [[ "${ZOT_PID}" =~ ^[0-9]+$ ]] || return 0
    CL_ZOT=false
    if zot_alive; then
        stop_tree "${ZOT_PID}"
        poll_until "${STOP_WAIT}" zot_gone || die "the local registry (PID ${ZOT_PID}) still runs" || return 1
    fi
    CL_ZOT=true
}

cleanup_sandbox() {
    CL_SANDBOX=null
    [[ -n "${S}" ]] || return 0
    if [[ "${KEEP}" == 1 ]]; then
        printf 'package-e2e.sh: kept %s; %s/key holds a private key\n' "${S}" "${S}"
        return 0
    fi
    CL_SANDBOX=false
    no_apiserver_under_root ||
        die "a sandbox apiserver may still run, so ${S} stays; run: scripts/package-e2e.sh run --recover" || return 1
    remove_sandbox "${ROOT}" "${RUN_ID}" "${S}" || return 1
    CL_SANDBOX=true
}

# cleanup STATUS: the actions of C-006 in order; each failure is exit 4 and the next action still runs.
cleanup() {
    local status="$1" rc=0
    set +e
    [[ "${CLEANED}" == 0 ]] || return 0
    CLEANED=1
    cleanup_containers || rc=4
    cleanup_sandbox_services || rc=4
    cleanup_stock || rc=4
    cleanup_keychain || rc=4
    cleanup_zot || rc=4
    cleanup_sandbox || rc=4
    if [[ "${status}" -ne 0 ]]; then
        FINAL_STATUS="${status}"
        RESULT=fail
        [[ "${REFUSED}" != 1 ]] || RESULT=refused
    elif [[ "${rc}" -ne 0 ]]; then
        FINAL_STATUS=4
        RESULT=fail
    else
        FINAL_STATUS=0
        RESULT=pass
    fi
    write_receipt || FINAL_STATUS=4
    release_lock
}

# on_exit: the killed step's process tree is gone before cleanup starts, so cleanup never deletes the
# keychain item while parbake create may still write it.
on_exit() {
    local status=$?
    set +e
    trap '' INT TERM HUP PIPE QUIT
    kill_timed
    if [[ "${RECOVER}" == 1 ]]; then
        release_lock
        exit "${status}"
    fi
    cleanup "${status}"
    printf 'RESULT %s %s\n' "${RESULT}" "${RECEIPT}"
    exit "${FINAL_STATUS}"
}

# --- recover ---------------------------------------------------------------------------------

# recover_run: stops the apiserver a killed run left under ROOT, restarts the stock services when
# a stale sandbox says they ran, and removes the stale sandboxes whose apiserver is stopped.
recover_run() {
    local program id cli entry rc=0 restart=0 skip=""
    [[ -d "${ROOT}" ]] || {
        printf 'nothing to recover under %s\n' "${ROOT}"
        return 0
    }
    p03_attended || return 3
    acquire_lock || return 3
    program="$(apiserver_program)"
    case "${program}" in
        "" | "${STOCK_PROGRAM}") ;;
        "${ROOT}/"*)
            id="${program#"${ROOT}/"}"
            id="${id%%/*}"
            cli="${ROOT}/${id}/root/bin/container"
            if [[ "${id}" =~ ${RUN_ID_RE} && -x "${cli}" ]] && bounded "${CLEAN_TIMEOUT}" "${cli}" system stop &&
                poll_until "${STOP_WAIT}" recover_gone; then
                :
            else
                die "cannot stop the apiserver ${program}" || rc=4
                skip="${id}"
            fi
            ;;
        *) refuse P08 "a foreign apiserver runs: ${program}" || return 3 ;;
    esac
    for entry in "${ROOT}"/*; do
        id="$(basename "${entry}")"
        [[ "${id}" =~ ${RUN_ID_RE} ]] || continue
        ! grep -qx 'stock_ran=1' "${entry}/state" 2>/dev/null || restart=1
        if [[ "${id}" == "${skip}" ]] || ! no_apiserver_under_root; then
            die "keeping the sandbox ${id}: its apiserver may still run" || rc=4
            continue
        fi
        if bounded 30 "${T_SECURITY}" find-generic-password -s "container-runtime-macos.e2e.${id}"; then
            delete_run_keychain_item "container-runtime-macos.e2e.${id}" || die "cannot delete the keychain item of ${id}" || rc=4
        fi
        remove_sandbox "${ROOT}" "${id}" "${entry}" || rc=4
        printf 'removed the sandbox %s\n' "${id}"
    done
    if [[ "${restart}" == 1 && -z "$(apiserver_program)" ]]; then
        if [[ -x "${STOCK_CLI}" ]] && bounded "${CLEAN_TIMEOUT}" "${STOCK_CLI}" system start && poll_until "${STOCK_WAIT}" stock_running; then
            printf 'the stock services run again\n'
            for entry in "${ROOT}"/*; do
                if [[ -f "${entry}/state" ]]; then printf 'stock_ran=0\n' >"${entry}/state"; fi
            done
        else
            die "the stock services did not start; run by hand: ${STOCK_CLI} system start" || rc=4
        fi
    fi
    return "${rc}"
}

recover_gone() { [[ "$(apiserver_program)" != "${ROOT}/"* ]]; }

# --- run -------------------------------------------------------------------------------------

# --- steps -----------------------------------------------------------------------------------

readonly CONTAINER_VERSION_RE='^container CLI version parbake-[0-9a-f]+ .*commit: [0-9a-f]+'
# Network signatures only. "Not authorized: url .../referrers/" is the known registry referrers 401
# that clears on a retry; a bare "registry operation failed" or "ssl" is not one.
readonly NETWORK_RE='could not resolve|connection (refused|reset)|timed out|network is unreachable|tls handshake|http 5[0-9][0-9]|status code 5[0-9][0-9]|not authorized: url [^ ]*/referrers/'

# pid_alive PID: PID runs and is not a zombie.
pid_alive() {
    local state
    kill -0 "$1" 2>/dev/null || return 1
    state="$(/bin/ps -o state= -p "$1" 2>/dev/null)" || return 1
    [[ -n "${state}" && "${state}" != Z* ]]
}

# tree_pids PID: the descendants of PID and PID itself, one per line, children first.
tree_pids() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null || true); do
        tree_pids "${child}"
    done
    printf '%s\n' "$1"
}

# signal_pids SIGNAL PIDS: SIGNAL to each PID of the newline-separated list; never PID 0, 1 or a group.
signal_pids() {
    local pid
    while IFS= read -r pid; do
        [[ "${pid}" =~ ^[0-9]+$ && "${pid}" -gt 1 ]] || continue
        kill "-${1}" "${pid}" 2>/dev/null || true
    done <<<"$2"
}

any_alive() {
    local pid
    while IFS= read -r pid; do
        [[ "${pid}" =~ ^[0-9]+$ && "${pid}" -gt 1 ]] || continue
        if pid_alive "${pid}"; then return 0; fi
    done <<<"$1"
    return 1
}

# stop_tree PID: TERM to PID and its descendants, up to KILL_GRACE seconds for them to exit, then
# KILL to what is left, and a few seconds for that to take effect.
stop_tree() {
    local root="$1" pids end
    [[ "${root}" =~ ^[0-9]+$ && "${root}" -gt 1 ]] || return 0
    pids="$(tree_pids "${root}")"
    signal_pids TERM "${pids}"
    end=$((SECONDS + KILL_GRACE))
    while any_alive "${pids}" && [[ "${SECONDS}" -lt "${end}" ]]; do
        sleep "${TIMED_POLL}"
    done
    if any_alive "${pids}"; then
        pids="${pids}"$'\n'"$(tree_pids "${root}")"
        signal_pids KILL "${pids}"
        end=$((SECONDS + 5))
        while any_alive "${pids}" && [[ "${SECONDS}" -lt "${end}" ]]; do
            sleep "${TIMED_POLL}"
        done
    fi
}

# kill_timed: the command a timeout helper still waits on, when a signal ended the run. Returns once
# its whole process tree is gone.
kill_timed() {
    [[ "${TIMED_PID}" =~ ^[0-9]+$ ]] || return 0
    stop_tree "${TIMED_PID}"
    if ! pid_alive "${TIMED_PID}"; then wait "${TIMED_PID}" 2>/dev/null || true; fi
    TIMED_PID=""
}

# run_timed SECONDS OUT ERR COMMAND...: COMMAND with stdout in OUT and stderr in ERR. Returns its
# status, or 124 when it ran past SECONDS or past the total deadline (TIMED_LIMIT says which). The
# child gets the default INT, TERM, HUP, PIPE and QUIT dispositions: cleanup ignores them in the
# shell, and an inherited ignore would make the child immune to the timeout.
run_timed() {
    local secs="$1" out="$2" err="$3" end start pid remain rc=0
    shift 3
    TIMED_LIMIT=step
    remain=$((DEADLINE - SECONDS))
    if [[ "${remain}" -le 0 ]]; then
        TIMED_LIMIT=total
        : >"${out}"
        : >"${err}"
        return 124
    fi
    if [[ "${remain}" -lt "${secs}" ]]; then
        secs="${remain}"
        TIMED_LIMIT=total
    fi
    (
        trap - INT TERM HUP PIPE QUIT
        "$@"
    ) >"${out}" 2>"${err}" </dev/null &
    pid=$!
    TIMED_PID="${pid}"
    start="${SECONDS}"
    end=$((SECONDS + secs))
    while kill -0 "${pid}" 2>/dev/null; do
        if [[ "${SECONDS}" -ge "${end}" ]]; then
            kill_timed
            return 124
        fi
        if [[ "${TIMED_HINT_AFTER}" -gt 0 && $((SECONDS - start)) -ge "${TIMED_HINT_AFTER}" ]]; then
            printf 'package-e2e.sh: %s\n' "${TIMED_HINT}" >&2
            TIMED_HINT_AFTER=0
        fi
        sleep "${TIMED_POLL}"
    done
    wait "${pid}" || rc=$?
    TIMED_PID=""
    return "${rc}"
}

# capture SECONDS COMMAND...: run_timed into the sandbox; sets CAP_RC, CAP_OUT and CAP_ERR.
capture() {
    local secs="$1"
    shift
    CAP_RC=0
    run_timed "${secs}" "${S}/.out" "${S}/.err" "$@" || CAP_RC=$?
    CAP_OUT="$(<"${S}/.out")"
    CAP_ERR="$(<"${S}/.err")"
}

# cap_class: product, network or timeout for the last capture.
cap_class() {
    if [[ "${CAP_RC}" -eq 124 ]]; then
        printf 'timeout'
    elif printf '%s\n%s\n' "${CAP_OUT}" "${CAP_ERR}" | grep -Eiq "${NETWORK_RE}"; then
        printf 'network'
    else
        printf 'product'
    fi
}

# capture_retry SECONDS COMMAND...: capture, and once more after a network failure.
capture_retry() {
    local secs="$1"
    shift
    capture "${secs}" "$@"
    if [[ "${CAP_RC}" -ne 0 && "$(cap_class)" == network ]]; then
        printf 'package-e2e.sh: network failure, retrying once\n' >&2
        sleep "${POLL_INTERVAL}"
        capture "${secs}" "$@"
    fi
}

# step_fail CLASS MESSAGE: the step detail "CLASS: MESSAGE"; always returns 1.
step_fail() {
    STEP_DETAIL="$1: $2"
    return 1
}

# cap_fail WHAT: the step fails on the last capture, with its class and output.
cap_fail() {
    local class text
    class="$(cap_class)"
    if [[ "${class}" == timeout ]]; then
        if [[ "${TIMED_LIMIT}" == total ]]; then
            step_fail timeout "the total timeout of ${PKG_E2E_TOTAL_TIMEOUT:-5400}s ended $1"
        else
            step_fail timeout "$1 ran past its time limit"
        fi
        return 1
    fi
    text="${CAP_ERR:-${CAP_OUT}}"
    step_fail "${class}" "$1 exited ${CAP_RC}: $(filter_msg <<<"${text}")"
}

# ocx_run HOME ARGS...: ocx in a hermetic environment. OCX_INSECURE_REGISTRIES is set only on a
# call that names the local registry.
ocx_run() {
    local home="$1" arg insecure=()
    shift
    if [[ -n "${ZOT_PORT}" ]]; then
        for arg in "$@"; do
            if [[ "${arg}" == "127.0.0.1:${ZOT_PORT}/"* ]]; then
                insecure=("OCX_INSECURE_REGISTRIES=127.0.0.1:${ZOT_PORT}")
            fi
        done
    fi
    env "OCX_HOME=${home}" OCX_NO_CONFIG=1 OCX_NO_PROJECT=1 "DOCKER_CONFIG=${S}/docker" OCX_NO_UPDATE_CHECK=1 \
        ${insecure[@]+"${insecure[@]}"} "${T_OCX}" --config "${S}/trust.toml" "$@"
}

ocx_call() { ocx_run "${S}/ocx" "$@"; }

# run_ref KIND: the reference the later steps use for KIND, pinned by digest.
run_ref() {
    if [[ "$1" == container ]]; then
        printf '%s@%s' "${CONTAINER_PKG_REF}" "${CONTAINER_DIGEST}"
    else
        printf '%s@%s' "${PARBAKE_PKG_REF}" "${PARBAKE_DIGEST}"
    fi
}

parbake_version() {
    if [[ "${MODE}" == candidate ]]; then printf '%s' "${CANDIDATE_VERSION}"; else ref_tag "${PARBAKE_PKG_REF}"; fi
}

# run_step ID FUNCTION: one step: the "==> ID name" line, the deadline check, the receipt entry.
run_step() {
    local id="$1" fn="$2" name="" entry result=pass rc=0 t0
    for entry in "${STEPS[@]}"; do
        if [[ "${entry%%:*}" == "${id}" ]]; then name="${entry#*:}"; fi
    done
    printf '==> %s %s\n' "${id}" "${name}"
    STEP_DETAIL=""
    STEP_SKIP=0
    STEP_WARN=0
    t0="${SECONDS}"
    if [[ "${SECONDS}" -ge "${DEADLINE}" ]]; then
        step_fail timeout "the total timeout of ${PKG_E2E_TOTAL_TIMEOUT:-5400}s ended before ${id}" || rc=1
    else
        "${fn}" || rc=$?
    fi
    if [[ "${rc}" -ne 0 ]]; then
        result=fail
    elif [[ "${STEP_SKIP}" == 1 ]]; then
        result=skip
    elif [[ "${STEP_WARN}" == 1 ]]; then
        result=warn
    fi
    record_step "${id}" "${name}" "${result}" "$((SECONDS - t0))" "${STEP_DETAIL}"
    if [[ "${result}" == fail ]]; then
        die "${id} ${name} failed: $(filter_msg <<<"${STEP_DETAIL}")" || return 1
    fi
}

step_skip() {
    STEP_SKIP=1
    STEP_DETAIL="$1"
}

# verify_pkg KIND IDENTITY: ocx package verify of the pinned reference with the quickstart identity.
# The JSON output names the identity the signature carries; it must equal IDENTITY exactly.
verify_pkg() {
    local kind="$1" identity="$2" row
    capture 120 ocx_call --format json package verify -p darwin/arm64 --certificate-identity "${identity}" --certificate-oidc-issuer "${OIDC_ISSUER}" "$(run_ref "${kind}")"
    [[ "${CAP_RC}" -eq 0 ]] || cap_fail "verify" || return 1
    row="$("${T_PLUTIL}" -extract data.certificate_identity raw -o - - <<<"${CAP_OUT}" 2>/dev/null)" || row=""
    [[ "${row}" == "${identity}" ]] || step_fail product "the certificate identity is \"${row}\", expected \"${identity}\"" || return 1
    STEP_DETAIL="signed by ${identity}"
}

e01_trust_policy() {
    printf '%s\n' "${TRUST_POLICY}" >"${S}/trust.toml" && chmod 600 "${S}/trust.toml" ||
        step_fail product "cannot write trust.toml" || return 1
    STEP_DETAIL="two policies written"
}

e02_verify_container() {
    if [[ "${MODE}" == candidate ]]; then
        step_skip "candidate mode"
        return 0
    fi
    verify_pkg container "${CONTAINER_IDENTITY_PREFIX}$(ref_tag "${CONTAINER_PKG_REF}")" || return 1
    CONTAINER_VERIFIED=true
}

e03_verify_parbake() {
    if [[ "${MODE}" == candidate ]]; then
        step_skip "candidate mode"
        return 0
    fi
    verify_pkg parbake "${PARBAKE_IDENTITY_PREFIX}$(ref_tag "${PARBAKE_PKG_REF}")" || return 1
    PARBAKE_VERIFIED=true
}

e04_verify_negative() {
    if [[ "${MODE}" == candidate ]]; then
        step_skip "the candidate is unsigned"
        return 0
    fi
    capture 120 ocx_call package verify -p darwin/arm64 --certificate-identity "${PARBAKE_IDENTITY_PREFIX}0.0.0-e2e" --certificate-oidc-issuer "${OIDC_ISSUER}" "$(run_ref parbake)"
    if [[ "${CAP_RC}" -eq 124 || "${CAP_RC}" -ne 77 && "$(cap_class)" == network ]]; then
        cap_fail "the negative verify" || return 1
    fi
    [[ "${CAP_RC}" -eq 77 ]] || step_fail product "the negative verify exited ${CAP_RC}, expected 77" || return 1
    printf '%s\n%s\n' "${CAP_OUT}" "${CAP_ERR}" | grep -Fiq 'certificate identity mismatch' ||
        step_fail product "exit 77 without the message \"certificate identity mismatch\"" || return 1
    STEP_DETAIL="exit 77, certificate identity mismatch"
}

# choose_port: sets ZOT_CHOSEN to a free port of 49152 to 50151.
choose_port() {
    local port
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        port=$((49152 + RANDOM % 1000))
        if [[ -z "$("${T_LSOF}" -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)" ]]; then
            ZOT_CHOSEN="${port}"
            return 0
        fi
    done
    return 1
}

# zot_bound PORT: the zot process listens on 127.0.0.1:PORT and nothing else does.
zot_bound() {
    local out
    out="$("${T_LSOF}" -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true)"
    awk -v pid="${ZOT_PID}" -v addr="127.0.0.1:$1" 'NR > 1 { n++; if ($2 == pid && index($0, addr)) ok++ } END { exit !(n == 1 && ok == 1) }' <<<"${out}"
}

# start_zot: installs the pinned zot, starts it on 127.0.0.1 and waits for its listener.
start_zot() {
    local port end
    mkdir -m 700 "${S}/zot/data" 2>/dev/null || true
    capture_retry 600 ocx_run "${S}/zot/ocx" package install --link "${S}/zot/link" "${PKG_E2E_ZOT_REF}"
    [[ "${CAP_RC}" -eq 0 ]] || cap_fail "the zot install" || return 1
    ZOT_BIN="${S}/zot/link/content/zot"
    [[ -x "${ZOT_BIN}" ]] || step_fail product "the zot package holds no content/zot" || return 1
    choose_port || step_fail product "no free port between 49152 and 50151" || return 1
    port="${ZOT_CHOSEN}"
    printf '{\n  "distSpecVersion": "1.1.1",\n  "storage": { "rootDirectory": "%s/zot/data" },\n  "http": { "address": "127.0.0.1", "port": "%s" }\n}\n' "${S}" "${port}" >"${S}/zot/config.json" ||
        step_fail product "cannot write the zot config" || return 1
    "${ZOT_BIN}" serve "${S}/zot/config.json" >"${S}/zot/zot.log" 2>&1 </dev/null &
    ZOT_PID=$!
    end=$((SECONDS + ZOT_WAIT))
    while ! zot_bound "${port}"; do
        kill -0 "${ZOT_PID}" 2>/dev/null || step_fail product "zot exited: $(filter_msg <"${S}/zot/zot.log")" || return 1
        [[ "${SECONDS}" -lt "${end}" && "${SECONDS}" -lt "${DEADLINE}" ]] ||
            step_fail timeout "zot is not bound to 127.0.0.1:${port} after ${ZOT_WAIT}s" || return 1
        sleep "${POLL_INTERVAL}"
    done
    ZOT_PORT="${port}"
}

# push_candidate KIND ARCHIVE REF: pushes ARCHIVE and its metadata to the local registry as REF.
push_candidate() {
    local archive="$2" ref="$3"
    capture 300 ocx_call package push -p darwin/arm64 -i "${ref}" -m "${archive%.tar.xz}-metadata.json" -- "${archive}"
    [[ "${CAP_RC}" -eq 0 ]] || cap_fail "the push of ${ref}" || return 1
}

e05_local_registry() {
    local local_parbake local_container archive
    if [[ "${MODE}" == published ]]; then
        step_skip "published mode"
        return 0
    fi
    start_zot || return 1
    local_parbake="127.0.0.1:${ZOT_PORT}/extra-code/parbake:${CANDIDATE_VERSION}"
    push_candidate parbake "${PACKAGE_DIR}/parbake-${CANDIDATE_VERSION}.tar.xz" "${local_parbake}" || return 1
    PARBAKE_PKG_REF="${local_parbake}"
    PARBAKE_DIGEST="$(ref_digest "${local_parbake}")" || step_fail network "cannot read the pushed digest of ${local_parbake}" || return 1
    archive="${PKG_E2E_CONTAINER_ARCHIVE:-}"
    if [[ -n "${archive}" ]]; then
        local_container="127.0.0.1:${ZOT_PORT}/extra-code/container:$(ref_tag "${CONTAINER_REF}")"
        push_candidate container "${archive}" "${local_container}" || return 1
        CONTAINER_PKG_REF="${local_container}"
        CONTAINER_DIGEST="$(ref_digest "${local_container}")" || step_fail network "cannot read the pushed digest of ${local_container}" || return 1
    fi
    # The candidate is unsigned. Exit 79 as "no signature" is not confirmed against a live run, so any
    # other exit is a warn with the code, not a failure.
    capture 120 ocx_call package verify -p darwin/arm64 --certificate-identity "${PARBAKE_IDENTITY_PREFIX}${CANDIDATE_VERSION}" --certificate-oidc-issuer "${OIDC_ISSUER}" "$(run_ref parbake)"
    PARBAKE_VERIFIED=false
    if [[ "${CAP_RC}" -eq 79 ]]; then
        STEP_DETAIL="pushed to 127.0.0.1:${ZOT_PORT}, unsigned (verify exit 79)"
    else
        [[ "${CAP_RC}" -ne 0 ]] || PARBAKE_VERIFIED=true
        STEP_WARN=1
        STEP_DETAIL="pushed to 127.0.0.1:${ZOT_PORT}; verify of the candidate exited ${CAP_RC}, expected 79"
    fi
}

# install_pkg KIND LINK: ocx package install by digest; the unverified line is an error unless the
# package comes from the local registry. A package counts as verified only with proof: a published
# one when its verify step passed, a local one when the push step found a signature.
install_pkg() {
    local kind="$1" link="$2" ref expect_unverified=0 unverified=0 verified=false prior
    ref="$(run_ref "${kind}")"
    [[ "${ref}" != "127.0.0.1:"* ]] || expect_unverified=1
    capture_retry 600 ocx_call package install --link "${link}" "${ref}"
    [[ "${CAP_RC}" -eq 0 ]] || cap_fail "the install of ${ref}" || return 1
    [[ -e "${link}" ]] || step_fail product "the install left no link at ${link}" || return 1
    if printf '%s\n%s\n' "${CAP_OUT}" "${CAP_ERR}" | grep -Eiq 'no trust policy covers|without signature verification'; then
        unverified=1
    fi
    if [[ "${unverified}" == 1 && "${expect_unverified}" == 0 ]]; then
        step_fail product "no trust policy covers ${ref}; it was installed without signature verification" || return 1
    fi
    if [[ "${kind}" == container ]]; then prior="${CONTAINER_VERIFIED}"; else prior="${PARBAKE_VERIFIED}"; fi
    if [[ "${unverified}" == 0 ]]; then
        if [[ "${expect_unverified}" == 1 ]]; then
            [[ "${prior}" != true ]] || verified=true
        elif [[ "${MODE}" == candidate || "${prior}" == true ]]; then
            verified=true
        fi
    fi
    if [[ "${kind}" == container ]]; then CONTAINER_VERIFIED="${verified}"; else PARBAKE_VERIFIED="${verified}"; fi
    STEP_DETAIL="installed, verified: ${verified}"
}

e06_install_container() { install_pkg container "${S}/link/container"; }
e07_install_parbake() { install_pkg parbake "${S}/link/plugin"; }

# sandbox_line LINE: a quickstart ln -s line with ~/.parbake/root as S/root and ~/.parbake as S/link.
sandbox_line() {
    local line="$1" tilde="~" tpl_root tpl_base
    tpl_root="${tilde}/.parbake/root"
    tpl_base="${tilde}/.parbake"
    line=${line//"${tpl_root}"/${S}/root}
    line=${line//"${tpl_base}"/${S}/link}
    printf '%s' "${line#ln -s }"
}

e08_build_root() {
    local line pair src dst
    mkdir -p "${S}/root/libexec/container-plugins" || step_fail product "cannot create the root" || return 1
    for line in "${LINK_BIN}" "${LINK_LIBEXEC}" "${LINK_PLUGIN}"; do
        pair="$(sandbox_line "${line}")"
        src="${pair%% *}"
        dst="${pair#* }"
        ln -s "${src}" "${dst}" || step_fail product "cannot link ${dst}" || return 1
    done
    [[ -e "${S}/root/libexec/container-plugins/container-runtime-macos/config.toml" ]] ||
        step_fail product "the plugin config.toml is missing under the root" || return 1
    STEP_DETAIL="three links"
}

e09_versions() {
    local out expected
    capture 60 "${S}/root/bin/container" --version
    [[ "${CAP_RC}" -eq 0 ]] || cap_fail "container --version" || return 1
    [[ "${CAP_OUT}" =~ ${CONTAINER_VERSION_RE} ]] ||
        step_fail product "unexpected container version \"${CAP_OUT}\"" || return 1
    out="${CAP_OUT}"
    capture 60 ocx_call package exec "$(run_ref parbake)" -- parbake --version
    [[ "${CAP_RC}" -eq 0 ]] || cap_fail "parbake --version" || return 1
    expected="$(parbake_version)"
    [[ "${CAP_OUT}" == "${expected}" ]] || step_fail product "parbake --version printed \"${CAP_OUT}\", expected \"${expected}\"" || return 1
    STEP_DETAIL="${out%% (*}, parbake ${expected}"
}

e10_stop_stock() {
    local list=""
    if stock_running; then
        list="$("${STOCK_CLI}" ls -a --quiet 2>/dev/null)" || step_fail product "cannot list the stock containers" || return 1
    fi
    [[ -z "${list}" ]] || step_fail product "stock containers appeared: $(tr '\n' ' ' <<<"${list}")" || return 1
    record_stock_state || step_fail product "cannot write the stock state" || return 1
    if grep -qx 'stock_ran=1' "${S}/state"; then
        capture 120 "${STOCK_CLI}" system stop
        [[ "${CAP_RC}" -eq 0 ]] || cap_fail "container system stop" || return 1
    fi
    poll_until "${STOP_WAIT}" sandbox_apiserver_free ||
        step_fail product "an apiserver still runs: $(apiserver_program)" || return 1
    STEP_DETAIL="stock services stopped"
}

sandbox_apiserver_free() { [[ -z "$(apiserver_program)" ]]; }

# canon_path PATH: PATH with its directory resolved (cd -P), or PATH itself when that fails.
canon_path() {
    local dir
    if dir="$(cd -P "$(dirname "$1")" 2>/dev/null && pwd -P)"; then
        printf '%s/%s' "${dir%/}" "$(basename "$1")"
    else
        printf '%s' "$1"
    fi
}

# sandbox_program_ok PROGRAM: launchd records the resolved store path under S/ocx/packages/; the
# unresolved S/root/bin/container-apiserver is accepted too. Compared in canonical form.
sandbox_program_ok() {
    local program="$1" canon real_ocx
    canon="$(canon_path "${program}")"
    real_ocx="$(cd -P "${S}/ocx" && pwd -P)" || return 1
    [[ "${program}" == "${S}/ocx/packages/"* || "${canon}" == "${real_ocx}/packages/"* ||
        "${canon}" == "$(canon_path "${S}/root/bin/container-apiserver")" ]]
}

e11_start_sandbox() {
    local program
    capture 180 "${S}/root/bin/container" system start --install-root "${S}/root" --app-root "${S}/app" --disable-kernel-install
    [[ "${CAP_RC}" -eq 0 ]] || cap_fail "container system start" || return 1
    program="$(apiserver_program)"
    sandbox_program_ok "${program}" ||
        step_fail product "the apiserver program is \"${program}\", not a path under the sandbox packages" || return 1
    STEP_DETAIL="apiserver from the sandbox packages"
}

e12_create_bundle() {
    local args=()
    assert_service "${KEYCHAIN_SERVICE}" || step_fail product "invalid keychain service" || return 1
    args=(create --bundle "${S}/bundle/VM.bundle" --cache-dir "${S}/cache" --username ci
        --authorized-key "${S}/key/id_ed25519.pub" --keychain --keychain-service "${KEYCHAIN_SERVICE}")
    if [[ -n "${PKG_E2E_RESTORE_IMAGE:-}" ]]; then
        args+=(--restore-image "${PKG_E2E_RESTORE_IMAGE}")
    fi
    KEYCHAIN_OWNED=1
    TIMED_HINT_AFTER=600
    TIMED_HINT="parbake create is still running after 10 minutes; a restore image download or install can take long"
    capture 3600 ocx_call package exec "$(run_ref parbake)" -- parbake "${args[@]}"
    TIMED_HINT_AFTER=0
    [[ "${CAP_RC}" -ne 69 ]] ||
        step_fail product "parbake create exited 69: the login keychain is locked; unlock it with: security unlock-keychain" || return 1
    [[ "${CAP_RC}" -eq 0 ]] || cap_fail "parbake create" || return 1
    printf '%s\n%s\n' "${CAP_OUT}" "${CAP_ERR}" | grep -Fxq "==> Created ${S}/bundle/VM.bundle" ||
        step_fail product "parbake create did not print \"==> Created ${S}/bundle/VM.bundle\"" || return 1
    "${T_SECURITY}" find-generic-password -s "${KEYCHAIN_SERVICE}" >/dev/null 2>&1 ||
        step_fail product "no keychain item for ${KEYCHAIN_SERVICE}" || return 1
    STEP_DETAIL="bundle created"
}

e13_pull_and_run() {
    local name="e2e-${RUN_ID}" hint=""
    capture_retry 600 "${S}/root/bin/container" image pull alpine
    if [[ "${CAP_RC}" -ne 0 ]]; then
        if [[ "${CAP_RC}" -eq 124 ]] && "${T_SECURITY}" find-internet-password -s registry-1.docker.io >/dev/null 2>&1; then
            hint="; a registry login in the keychain may wait for a dialog (docs/package-troubleshooting.md)"
        fi
        cap_fail "container image pull alpine" || true
        STEP_DETAIL="${STEP_DETAIL}${hint}"
        return 1
    fi
    capture 120 "${S}/root/bin/container" run -d --name "${name}" --runtime container-runtime-macos \
        --label "runtime-macos.bundle=${S}/bundle/VM.bundle" --cpus 4 --memory 8G alpine
    [[ "${CAP_RC}" -eq 0 ]] || cap_fail "container run" || return 1
    printf '%s\n%s\n' "${CAP_OUT}" "${CAP_ERR}" | grep -Fq "${name}" ||
        step_fail product "container run did not print ${name}" || return 1
    STEP_DETAIL="started ${name}"
}

e14_wait_running() {
    local name="e2e-${RUN_ID}" end row="" cols=()
    end=$((SECONDS + ${PKG_E2E_RUN_TIMEOUT:-900}))
    while :; do
        capture 60 "${S}/root/bin/container" ls
        [[ "${CAP_RC}" -eq 0 ]] || cap_fail "container ls" || return 1
        row="$(awk -v n="${name}" '$1 == n { print; exit }' <<<"${CAP_OUT}")"
        if [[ -n "${row}" ]]; then
            read -r -a cols <<<"${row}"
            if [[ "${cols[4]:-}" == running && "${cols[5]:-}" =~ ^[0-9]+(\.[0-9]+){3}/[0-9]+$ ]]; then
                STEP_DETAIL="running at ${cols[5]}"
                return 0
            fi
        fi
        [[ "${SECONDS}" -lt "${end}" ]] || step_fail timeout "${name} is not running after ${PKG_E2E_RUN_TIMEOUT:-900}s; last row: ${row:-none}" || return 1
        [[ "${SECONDS}" -lt "${DEADLINE}" ]] ||
            step_fail timeout "the total timeout of ${PKG_E2E_TOTAL_TIMEOUT:-5400}s ended; last row: ${row:-none}" || return 1
        sleep "${LS_INTERVAL}"
    done
}

e15_exec_guest() {
    local name="e2e-${RUN_ID}" product version
    capture 120 "${S}/root/bin/container" exec "${name}" sw_vers
    [[ "${CAP_RC}" -eq 0 ]] || cap_fail "container exec sw_vers" || return 1
    product="$(sed -n 's/^ProductName:[[:space:]]*//p' <<<"${CAP_OUT}" | head -n 1)"
    version="$(sed -n 's/^ProductVersion:[[:space:]]*//p' <<<"${CAP_OUT}" | head -n 1)"
    [[ "${product}" == macOS ]] || step_fail product "the guest ProductName is \"${product}\"" || return 1
    [[ "${version}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || step_fail product "the guest ProductVersion is \"${version}\"" || return 1
    GUEST_MACOS="$(major_minor "${version}")"
    STEP_DETAIL="guest macOS ${GUEST_MACOS}"
}

e16_stop_remove() {
    local name="e2e-${RUN_ID}" verb
    for verb in stop rm; do
        capture 120 "${S}/root/bin/container" "${verb}" "${name}"
        [[ "${CAP_RC}" -eq 0 ]] || cap_fail "container ${verb}" || return 1
        printf '%s\n%s\n' "${CAP_OUT}" "${CAP_ERR}" | grep -Fq "${name}" ||
            step_fail product "container ${verb} did not print ${name}" || return 1
    done
    capture 60 "${S}/root/bin/container" ls -a --quiet
    [[ "${CAP_RC}" -eq 0 ]] || cap_fail "container ls -a" || return 1
    [[ -z "${CAP_OUT}" ]] || step_fail product "containers remain: $(tr '\n' ' ' <<<"${CAP_OUT}")" || return 1
    STEP_DETAIL="stopped and removed"
}

run_steps() {
    local fns=(
        e01_trust_policy e02_verify_container e03_verify_parbake e04_verify_negative
        e05_local_registry e06_install_container e07_install_parbake e08_build_root
        e09_versions e10_stop_stock e11_start_sandbox e12_create_bundle
        e13_pull_and_run e14_wait_running e15_exec_guest e16_stop_remove
    ) i
    for i in "${!fns[@]}"; do
        run_step "${STEPS[i]%%:*}" "${fns[i]}" || return 1
    done
}

# run_phase: the steps; the self-test replaces them with a case of its own.
run_phase() {
    if selftest_hooks_valid && [[ -n "${_PKG_E2E_SELFTEST_BIN:-}" && "${_PKG_E2E_SELFTEST_CASE:-}" =~ ^[a-z_]+$ ]]; then
        "st_case_${_PKG_E2E_SELFTEST_CASE}"
        return
    fi
    run_steps
}

# prepare_root: creates ROOT and its receipts directory and makes ROOT canonical. An existing ROOT
# must be empty or hold the marker; a directory without it is never chmod-ed or written to.
prepare_root() {
    local marker=".parbake-e2e-root" real
    if [[ -e "${ROOT}" ]]; then
        [[ -d "${ROOT}" && ! -L "${ROOT}" ]] || usage_error "PKG_E2E_ROOT ${ROOT} is not a plain directory" || return 2
        [[ -e "${ROOT}/${marker}" || -z "$(ls -A "${ROOT}")" ]] ||
            usage_error "PKG_E2E_ROOT ${ROOT} is not empty and holds no ${marker} marker" || return 2
    fi
    mkdir -p "${ROOT}" 2>/dev/null || die "cannot create ${ROOT}" || return 3
    real="$(cd -P "${ROOT}" && pwd -P)" || die "cannot resolve ${ROOT}" || return 3
    validate_root "${real}" || return 2
    ROOT="${real}"
    [[ -e "${ROOT}/${marker}" ]] || : >"${ROOT}/${marker}" || die "cannot create ${ROOT}/${marker}" || return 3
    mkdir -p "${ROOT}/receipts" 2>/dev/null && chmod 700 "${ROOT}" "${ROOT}/receipts" || die "cannot create ${ROOT}/receipts" || return 3
}

run() {
    local candidate="" keep=0 recover=0 mode=published rc=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --candidate)
                [[ $# -ge 2 ]] || usage_error "--candidate needs VERSION" || return 2
                [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage_error "candidate version \"$2\" is not X.Y.Z" || return 2
                candidate="$2"
                shift 2
                ;;
            --keep)
                keep=1
                shift
                ;;
            --recover)
                recover=1
                shift
                ;;
            *) usage_error "unknown option \"$1\"" || return 2 ;;
        esac
    done
    [[ -z "${candidate}" ]] || mode=candidate
    validate_params "${mode}" || return 2
    MODE="${mode}"
    CANDIDATE_VERSION="${candidate}"
    validate_candidate_files || return 2
    DEADLINE=$((SECONDS + ${PKG_E2E_TOTAL_TIMEOUT:-5400}))
    KEEP="${keep}"
    RECOVER="${recover}"
    ROOT="${PKG_E2E_ROOT:-${HOME}/.parbake-e2e}"
    STARTED="$(now)"
    RUN_ID="$(new_run_id)"
    [[ "${RUN_ID}" =~ ${RUN_ID_RE} ]] || die "cannot make a run id" || return 1
    readonly RUN_ID
    KEYCHAIN_SERVICE="container-runtime-macos.e2e.${RUN_ID}"
    prepare_root || return $?
    trap on_exit EXIT
    trap 'trap "" INT TERM HUP PIPE QUIT; exit 130' INT
    trap 'trap "" INT TERM HUP PIPE QUIT; exit 143' TERM
    trap 'trap "" INT TERM HUP PIPE QUIT; exit 129' HUP
    trap 'trap "" INT TERM HUP PIPE QUIT; exit 141' PIPE
    trap 'trap "" INT TERM HUP PIPE QUIT; exit 131' QUIT
    if [[ "${recover}" == 1 ]]; then
        recover_run || rc=$?
        exit "${rc}"
    fi
    acquire_lock || exit 3
    preflight || exit 3
    create_sandbox || exit $?
    run_phase || rc=$?
    exit "${rc}"
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

# expect_ok DESCRIPTION COMMAND...: the command succeeds.
expect_ok() {
    expect_code "$1" 0 "${@:2}"
}

# the usage text, flags and exit codes.
self_test_usage() {
    local out
    out="$("${SCRIPT_PATH}" --help)" || fail "--help exits non-zero"
    if [[ "${out}" == *"Usage:"* && "${out}" == *"PKG_E2E_ROOT"* && "${out}" != *"--- usage ---"* ]]; then
        pass "--help prints the usage header"
    else
        fail "--help output"
    fi
    expect_code "-h exits 0" 0 "${SCRIPT_PATH}" -h
    expect_code "no argument exits 2" 2 "${SCRIPT_PATH}"
    expect_code "a bad flag exits 2" 2 "${SCRIPT_PATH}" --frobnicate
    expect_code "a bad run flag exits 2" 2 st_script -- run --frobnicate
    expect_code "a bad candidate version exits 2" 2 st_script -- run --candidate 1.2
}

# the constants: ids and keys.
self_test_constants() {
    if [[ "${#STEPS[@]}" -eq 16 && "${STEPS[0]}" == E01:* && "${STEPS[15]}" == E16:* ]]; then
        pass "steps E01 to E16"
    else
        fail "step ids"
    fi
    if [[ "${#PREFLIGHTS[@]}" -eq 11 && "${#RECEIPT_KEYS[@]}" -eq 15 ]]; then
        pass "preflights P01 to P11 and 15 receipt keys"
    else
        fail "preflight ids or receipt keys"
    fi
}

# parameter and reference validation.
self_test_params() {
    local ref
    for ref in "ghcr.io/evil/x:1" "ghcr.io/extra-code/parbake:" "ghcr.io/extra-code/parbake:\$(id)" \
        "ghcr.io/extra-code/parbake:1.0.0@sha256:abc" "ghcr.io/extra-code/container:a b" "ghcr.io/extra-code/parbake"; do
        expect_code "reference \"${ref}\" exits 2" 2 st_script PKG_E2E_PARBAKE_REF="${ref}" -- run
        expect_code "container reference \"${ref}\" exits 2" 2 st_script PKG_E2E_CONTAINER_REF="${ref}" -- run
    done
    expect_code "a container reference for parbake exits 2" 2 st_script PKG_E2E_PARBAKE_REF="ghcr.io/extra-code/container:1.6.1_01" -- run
    expect_code "a valid reference passes validation" 0 st_script _PKG_E2E_SELFTEST_CASE=ok PKG_E2E_PARBAKE_REF="ghcr.io/extra-code/parbake:0.1.0" -- run
    expect_code "a reference in candidate mode exits 2" 2 st_script PKG_E2E_PARBAKE_REF="ghcr.io/extra-code/parbake:0.1.0" -- run --candidate 0.1.0
    expect_code "PKG_E2E_RUN_TIMEOUT=abc exits 2" 2 st_script PKG_E2E_RUN_TIMEOUT=abc -- run
    expect_code "PKG_E2E_MIN_FREE_GB=-1 exits 2" 2 st_script PKG_E2E_MIN_FREE_GB=-1 -- run
    expect_code "PKG_E2E_ROOT with .. exits 2" 2 st_script PKG_E2E_ROOT="${HOME}/a/../b" -- run
    expect_code "PKG_E2E_ROOT with a space exits 2" 2 st_script PKG_E2E_ROOT="${HOME}/a b" -- run
    expect_code "a relative PKG_E2E_ROOT exits 2" 2 st_script PKG_E2E_ROOT="e2e" -- run
    expect_code "PKG_E2E_ROOT outside home exits 2" 2 st_script PKG_E2E_ROOT="/var/tmp/e2e" -- run
    expect_code "PKG_E2E_ROOT equal to home exits 2" 2 st_script PKG_E2E_ROOT="${HOME}" -- run
    expect_code "a missing restore image exits 2" 2 st_script PKG_E2E_RESTORE_IMAGE="${WORK}/none.ipsw" -- run
    expect_code "an http restore image exits 2" 2 st_script PKG_E2E_RESTORE_IMAGE="http://example.com/x.ipsw" -- run
    expect_code "an https restore image with a query exits 2" 2 st_script PKG_E2E_RESTORE_IMAGE="https://example.com/x.ipsw?a=b" -- run
    : >"${WORK}/image.ipsw"
    expect_code "an existing restore image passes validation" 0 st_script _PKG_E2E_SELFTEST_CASE=ok PKG_E2E_RESTORE_IMAGE="${WORK}/image.ipsw" -- run
    expect_code "an https restore image passes validation" 0 st_script _PKG_E2E_SELFTEST_CASE=ok PKG_E2E_RESTORE_IMAGE="https://example.com/a/x.ipsw" -- run
    expect_code "a URL as archive exits 2" 2 st_script PKG_E2E_CONTAINER_ARCHIVE="https://example.com/c.tar.xz" -- run
    expect_code "an archive starting with - exits 2" 2 st_script PKG_E2E_CONTAINER_ARCHIVE="-x.tar.xz" -- run --candidate 1.2.3
    expect_code "PKG_E2E_MIN_FREE_GB=0900 exits 2" 2 st_script PKG_E2E_MIN_FREE_GB=0900 -- run
    expect_code "PKG_E2E_RUN_TIMEOUT with eight digits exits 2" 2 st_script PKG_E2E_RUN_TIMEOUT=12345678 -- run
    expect_code "PKG_E2E_TOTAL_TIMEOUT=0 passes validation" 0 st_script _PKG_E2E_SELFTEST_CASE=ok PKG_E2E_TOTAL_TIMEOUT=0 -- run
    expect_code "PKG_E2E_ROOT with // exits 2" 2 st_script PKG_E2E_ROOT="${HOME}/a//b" -- run
    expect_code "PKG_E2E_ROOT with /./ exits 2" 2 st_script PKG_E2E_ROOT="${HOME}/./b" -- run
    expect_code "PKG_E2E_ROOT with a trailing / exits 2" 2 st_script PKG_E2E_ROOT="${HOME}/b/" -- run
    expect_code "PKG_E2E_ROOT ending in /.. exits 2" 2 st_script PKG_E2E_ROOT="${HOME}/b/.." -- run
    mkdir -m 755 "${HOME}/foreign"
    : >"${HOME}/foreign/file"
    expect_code "a non-empty PKG_E2E_ROOT without the marker exits 2" 2 st_script PKG_E2E_ROOT="${HOME}/foreign" -- run
    st_check "the unmarked directory kept its mode and got no marker" \
        test "$(stat -f %Lp "${HOME}/foreign")" = 755 -a ! -e "${HOME}/foreign/.parbake-e2e-root" -a ! -e "${HOME}/foreign/receipts"
    rm -rf "${HOME}/foreign"
}

# doc_lines FILE: the file with the list indentation of three spaces removed.
doc_lines() {
    sed 's/^   //' "$1"
}

# doc_policy_block: the quickstart's heredoc body.
doc_policy_block() {
    doc_lines "${QUICKSTART}" | awk '
        /^cat >> ~\/\.ocx\/config\.toml <<.EOF.$/ { inside = 1; next }
        inside && /^EOF$/ { exit }
        inside { print }'
}

doc_has_policy() {
    [[ "$(doc_policy_block)" == "${TRUST_POLICY}" ]]
}

doc_has_identities() {
    grep -Fq -- "${CONTAINER_IDENTITY_PREFIX}" "${QUICKSTART}" &&
        grep -Fq -- "${PARBAKE_IDENTITY_PREFIX}" "${QUICKSTART}" &&
        grep -Fq -- "${OIDC_ISSUER}" "${QUICKSTART}"
}

doc_has_links() {
    local lines line
    lines="$(doc_lines "${QUICKSTART}")"
    for line in "${LINK_BIN}" "${LINK_LIBEXEC}" "${LINK_PLUGIN}"; do
        grep -Fxq -- "${line}" <<<"${lines}" || return 1
    done
}

# doc_has_exit_codes: the sentence with 79 says no signature, the one with 77 says mismatch.
doc_has_exit_codes() {
    local sentences
    sentences="$(grep -E '77' "${QUICKSTART}" | grep -E '79' | awk '{ n = split($0, a, /\. /); for (i = 1; i <= n; i++) print a[i] }')"
    [[ -n "${sentences}" ]] || return 1
    grep -E '79' <<<"${sentences}" | grep -Eiq 'no signature|not found' || return 1
    grep -E '77' <<<"${sentences}" | grep -Eiq 'does not match|mismatch'
}

# doc_has_registry_hint: the troubleshooting page names the first-run wait and the keychain service.
# shellcheck disable=SC2016 # the backticks are literal
doc_has_registry_hint() {
    grep -Fxq '## Error: the first `run` waits at `[0/6]`' "${TROUBLESHOOTING}" &&
        grep -Fq 'com.apple.container.registry' "${TROUBLESHOOTING}"
}

self_test_docs() {
    expect_ok "docs/quickstart.md holds the trust policy block verbatim" doc_has_policy
    expect_ok "docs/quickstart.md names both certificate identities and the issuer" doc_has_identities
    expect_ok "docs/quickstart.md holds the three ln -s lines" doc_has_links
    expect_ok "docs/quickstart.md states exit 79 for no signature and 77 for a mismatch" doc_has_exit_codes
    expect_ok "docs/package-troubleshooting.md explains the first-run wait at [0/6]" doc_has_registry_hint
}

# repo_state: what the self-test must leave alone: the untracked and ignored files, and changes to
# tracked files under scripts.
repo_state() {
    (
        cd "${REPO_ROOT}"
        git diff --name-only -- scripts
        git status --porcelain --ignored --untracked-files=all | awk '
            /^(\?\?|!!) / {
                path = substr($0, 4)
                if (path ~ /^\.build(\/|$)/ || path ~ /^\.swiftpm(\/|$)/ || path ~ /^\.agents\/worktrees(\/|$)/ || path ~ /(^|\/)\.DS_Store$/) next
                print
            }'
    )
}

# --- stub world ------------------------------------------------------------------------------

# st_write_stubs: stubs for every tool the run calls. They keep their state and a call log in
# ST_STATE, and the log is what the cases assert on.
st_write_stubs() {
    local bin="${STUBS}" name
    mkdir -p "${bin}"
    cat >"${bin}/launchctl" <<'STUB'
#!/bin/bash
printf 'launchctl %s\n' "$*" >>"${ST_STATE}/calls.log"
if [[ "$1" == print ]]; then
    [[ ! -e "${ST_STATE}/launchctl_error" ]] || { echo "launchctl: transient failure" >&2; exit 1; }
    [[ -s "${ST_STATE}/apiserver_program" ]] || { echo "Could not find service" >&2; exit 113; }
    printf 'com.apple.container.apiserver = {\n\tstate = running\n\tprogram = %s\n}\n' "$(cat "${ST_STATE}/apiserver_program")"
    exit 0
fi
exit 0
STUB
    cat >"${bin}/security" <<'STUB'
#!/bin/bash
printf 'security %s\n' "$*" >>"${ST_STATE}/calls.log"
service=""
prev=""
for arg in "$@"; do
    case "${arg}" in -w | -g) echo "forbidden flag ${arg}" >&2; exit 98 ;; esac
    [[ "${prev}" != -s ]] || service="${arg}"
    prev="${arg}"
done
case "$1" in
    show-keychain-info) [[ ! -e "${ST_STATE}/keychain_locked" ]] || exit 36; exit 0 ;;
    find-generic-password) [[ -e "${ST_STATE}/keychain.${service}" || -e "${ST_STATE}/keychain_any" ]] || exit 44; echo "attributes"; exit 0 ;;
    find-internet-password) [[ -e "${ST_STATE}/docker_login" ]] || exit 44; exit 0 ;;
    delete-generic-password) [[ -e "${ST_STATE}/keychain.${service}" ]] || exit 44; rm -f "${ST_STATE}/keychain.${service}"; exit 0 ;;
esac
echo "unexpected security call" >&2
exit 99
STUB
    cat >"${bin}/sysctl" <<'STUB'
#!/bin/bash
if [[ -e "${ST_STATE}/hv" ]]; then cat "${ST_STATE}/hv"; else echo 0; fi
STUB
    cat >"${bin}/sw_vers" <<'STUB'
#!/bin/bash
if [[ -e "${ST_STATE}/macos" ]]; then cat "${ST_STATE}/macos"; else echo 27.0; fi
STUB
    cat >"${bin}/uname" <<'STUB'
#!/bin/bash
echo arm64
STUB
    cat >"${bin}/df" <<'STUB'
#!/bin/bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk1 1000 1 %s 1%% /\n' "$(cat "${ST_STATE}/df_kb")"
STUB
    cat >"${bin}/lsof" <<'STUB'
#!/bin/bash
printf 'lsof %s\n' "$*" >>"${ST_STATE}/calls.log"
port="${2#-iTCP:}"
[[ -e "${ST_STATE}/listen.${port}" ]] || exit 1
printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nzot %s u 5u IPv4 0x0 0t0 TCP 127.0.0.1:%s (LISTEN)\n' "$(cat "${ST_STATE}/listen.${port}")" "${port}"
STUB
    cat >"${bin}/ps" <<'STUB'
#!/bin/bash
[[ -e "${ST_STATE}/ps.$2" ]] && kill -0 "$2" 2>/dev/null || exit 1
cat "${ST_STATE}/ps.$2"
STUB
    cat >"${bin}/ssh-keygen" <<'STUB'
#!/bin/bash
printf 'ssh-keygen %s\n' "$*" >>"${ST_STATE}/calls.log"
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -f ]]; then : >"$2"; : >"$2.pub"; fi
    shift
done
STUB
    cat >"${bin}/ocx" <<'STUB'
#!/bin/bash
printf 'ocx %s\n' "$*" >>"${ST_STATE}/calls.log"
printf 'home=%s insecure=%s nocfg=%s noproj=%s docker=%s config=%s | %s\n' "${OCX_HOME:-}" "${OCX_INSECURE_REGISTRIES:-}" "${OCX_NO_CONFIG:-}" "${OCX_NO_PROJECT:-}" "${DOCKER_CONFIG:-}" "${OCX_CONFIG:-}" "$*" >>"${ST_STATE}/ocx_env.log"
if [[ "$1" == version ]]; then echo 0.6.5; exit 0; fi
if [[ "$*" == "--remote --format json index list --platforms "* ]]; then
    ref="${*: -1}"
    if grep -Fxq -- "${ref}" "${ST_STATE}/ocx_missing" 2>/dev/null; then echo '{}'; exit 0; fi
    printf '{\n  "%s": [\n    "darwin/arm64"\n  ]\n}\n' "${ref}"
    exit 0
fi
if [[ "$1" == --config ]]; then
    [[ -e "${ST_STATE}/trust.copy" ]] || cp "$2" "${ST_STATE}/trust.copy"
    shift 2
fi
fmt=""
if [[ "$1" == --format ]]; then
    fmt="$2"
    shift 2
fi
[[ ! -e "${ST_STATE}/ocx_sleep" ]] || sleep "$(cat "${ST_STATE}/ocx_sleep")"
last="${*: -1}"
case "$1 $2" in
    "package verify")
        identity=""
        prev=""
        for arg in "$@"; do
            [[ "${prev}" != --certificate-identity ]] || identity="${arg}"
            prev="${arg}"
        done
        if [[ "${last}" == 127.0.0.1:* ]]; then
            [[ ! -e "${ST_STATE}/verify_cand_rc" ]] || exit "$(cat "${ST_STATE}/verify_cand_rc")"
            echo "error: ${last}: no signature found" >&2
            exit 79
        fi
        if [[ "${identity}" == *v0.0.0-e2e ]]; then
            if [[ -e "${ST_STATE}/verify_msg_other" ]]; then echo "Error: ${last}: something else" >&2; else echo "Error: ${last}: certificate identity mismatch" >&2; fi
            exit 77
        fi
        [[ ! -e "${ST_STATE}/verify_bad_identity" ]] || identity="${identity}-other"
        printf '{"schema_version":1,"command":"package verify","exit_code":0,"data":{"subject_digest":"sha256:4ec5","referrer_digest":"sha256:ab12","certificate_identity":"%s"}}\n' "${identity}"
        exit 0
        ;;
    "package install")
        link=""
        prev=""
        for arg in "$@"; do
            [[ "${prev}" != --link ]] || link="${arg}"
            prev="${arg}"
        done
        echo "${last}" >>"${ST_STATE}/install_count"
        if [[ -e "${ST_STATE}/install_net_fail" && "$(wc -l <"${ST_STATE}/install_count")" -le "$(cat "${ST_STATE}/install_net_fail")" ]]; then
            echo "error: registry operation failed: connection reset by peer" >&2
            exit 69
        fi
        if [[ -e "${ST_STATE}/install_leak" ]]; then
            printf 'Authorization: Bearer x\nbad "quote" and\ttab\nsecond line\n' >&2
            exit 1
        fi
        [[ ! -e "${link}" ]] || { echo "error: ${link} exists" >&2; exit 65; }
        mkdir -p "${link}/content"
        case "${last}" in
            *zot*) cp "${ST_STUBS}/zot-bin" "${link}/content/zot" ;;
            */container:*)
                mkdir -p "${link}/content/bin" "${link}/content/libexec/container"
                cp "${ST_STUBS}/sandbox-container" "${link}/content/bin/container"
                ;;
            */parbake:*) : >"${link}/content/config.toml" ;;
        esac
        if [[ "${last}" == 127.0.0.1:* || -e "${ST_STATE}/ocx_unverified" ]]; then
            echo "no trust policy covers '${last%%@*}'; installing '${last}' without signature verification" >&2
        fi
        printf 'Package  Version  Path\n%s  x  %s\n' "${last}" "${link}"
        exit 0
        ;;
    "package push")
        ref=""
        prev=""
        for arg in "$@"; do
            [[ "${prev}" != -i ]] || ref="${arg}"
            prev="${arg}"
        done
        if [[ "${ref}" == 127.0.0.1:* && -z "${OCX_INSECURE_REGISTRIES:-}" ]]; then echo "error: plain http refused" >&2; exit 1; fi
        name="${ref#*/}"
        : >"${ST_STATE}/pushed.${name//[\/:]/_}"
        echo pushed
        exit 0
        ;;
    "package exec")
        ref="$3"
        shift 3
        [[ "$1" != -- ]] || shift
        case "$1 $2" in
            "parbake --version")
                tag="${ref%%@*}"
                echo "${tag##*:}"
                exit 0
                ;;
            "parbake create")
                bundle=""
                svc=""
                prev=""
                for arg in "$@"; do
                    [[ "${prev}" != --bundle ]] || bundle="${arg}"
                    [[ "${prev}" != --keychain-service ]] || svc="${arg}"
                    prev="${arg}"
                done
                [[ ! -e "${bundle}" ]] || { echo "error: ${bundle} already exists; pass --replace" >&2; exit 64; }
                [[ ! -e "${ST_STATE}/create_locked" ]] || { echo "error: keychain locked" >&2; exit 69; }
                [[ ! -e "${ST_STATE}/create_fail" ]] || { echo "error: create failed" >&2; exit 1; }
                : >"${ST_STATE}/keychain.${svc}"
                echo "==> Created ${bundle}"
                exit 0
                ;;
        esac
        ;;
esac
exit 99
STUB
    cat >"${bin}/curl" <<'STUB'
#!/bin/bash
printf 'curl %s\n' "$*" >>"${ST_STATE}/calls.log"
cat >/dev/null
[[ ! -e "${ST_STATE}/curl_fail" ]] || exit 22
url="${*: -1}"
case "${url}" in
    *"/token?scope="*) echo '{"token":"tok123"}' ;;
    *"/v2/"*"/manifests/"*)
        rest="${url#*/v2/}"
        repo="${rest%%/manifests/*}"
        tag="${rest##*/manifests/}"
        if [[ "${url}" == http://127.0.0.1:* ]]; then
            [[ -e "${ST_STATE}/pushed.${repo//\//_}_${tag}" ]] || exit 22
        fi
        [[ ! -e "${ST_STATE}/curl_nodigest" ]] || { printf 'HTTP/2 200\r\n\r\n'; exit 0; }
        printf 'HTTP/2 200\r\ncontent-type: x\r\nDocker-Content-Digest: sha256:%s\r\n\r\n' "$(printf '%s:%s' "${repo}" "${tag}" | shasum -a 256 | cut -c1-64)"
        ;;
    *) exit 22 ;;
esac
STUB
    cat >"${STUBS}/stubborn" <<'STUB'
#!/bin/bash
trap '' TERM
sleep 300 &
echo "$!" >"${ST_STATE}/stubborn_child"
echo "$$" >"${ST_STATE}/stubborn_pid"
: >"${ST_STATE}/ready"
while :; do sleep 1; done
STUB
    cat >"${STUBS}/zot-bin" <<'STUB'
#!/bin/bash
[[ ! -e "${ST_STATE}/zot_fail" ]] || { echo "zot: cannot start" >&2; exit 1; }
port="$(sed -n 's/.*"port": "\([0-9]*\)".*/\1/p' "$2")"
printf '%s serve %s\n' "$0" "$2" >"${ST_STATE}/ps.$$"
echo "$$" >"${ST_STATE}/zot_pid"
echo "$$" >"${ST_STATE}/listen.${port}"
trap 'rm -f "${ST_STATE}/listen.${port}" "${ST_STATE}/ps.$$"; exit 0' TERM
while :; do sleep 0.2; done
STUB
    cat >"${STUBS}/sandbox-container" <<'STUB'
#!/bin/bash
printf 'sandbox %s\n' "$*" >>"${ST_STATE}/calls.log"
case "$1 $2" in
    "--version ") echo "container CLI version parbake-1a2b3c4d (build: release, commit: 1234abc)" ;;
    "system start")
        root=""
        prev=""
        for arg in "$@"; do
            [[ "${prev}" != --install-root ]] || root="${arg}"
            prev="${arg}"
        done
        [[ ! -e "${ST_STATE}/sbx_start_fail" ]] || exit 1
        if [[ -e "${ST_STATE}/sbx_program_unresolved" ]]; then
            printf '%s\n' "${root}/bin/container-apiserver" >"${ST_STATE}/apiserver_program"
        else
            printf '%s\n' "$(dirname "${root}")/ocx/packages/x/bin/container-apiserver" >"${ST_STATE}/apiserver_program"
        fi
        ;;
    "system stop")
        [[ ! -e "${ST_STATE}/sbx_stop_hang" ]] || sleep 300
        [[ ! -e "${ST_STATE}/sbx_stop_fail" ]] || exit 1
        rm -f "${ST_STATE}/apiserver_program"
        ;;
    "ls -a") cat "${ST_STATE}/sbx_containers" 2>/dev/null || true ;;
    "ls ")
        echo "ID IMAGE OS ARCH STATE IP CPUS MEMORY STARTED"
        while IFS= read -r id; do
            [[ -z "${id}" ]] || printf '%s alpine:latest macOS arm64 %s 192.168.64.2/24 4 8192 MB 2026-10-30T10:00:00Z\n' "${id}" "$(cat "${ST_STATE}/sbx_row_state" 2>/dev/null || echo running)"
        done <"${ST_STATE}/sbx_containers"
        ;;
    "image pull")
        [[ ! -e "${ST_STATE}/pull_fail" ]] || { echo "error: dial tcp: connection refused" >&2; exit 1; }
        echo pulled
        ;;
    "run -d") echo "$4" >>"${ST_STATE}/sbx_containers"; echo "$4" ;;
    "exec "*) printf 'ProductName:\t\tmacOS\nProductVersion:\t\t%s\nBuildVersion:\t\t99A1\n' "$(cat "${ST_STATE}/guest_version" 2>/dev/null || echo 27.0.1)" ;;
    "stop "*) echo "$2" ;;
    "rm -f") grep -vFx -- "$3" "${ST_STATE}/sbx_containers" >"${ST_STATE}/sbx_containers.new" 2>/dev/null; mv -f "${ST_STATE}/sbx_containers.new" "${ST_STATE}/sbx_containers" ;;
    "rm "*)
        grep -vFx -- "$2" "${ST_STATE}/sbx_containers" >"${ST_STATE}/sbx_containers.new" 2>/dev/null
        mv -f "${ST_STATE}/sbx_containers.new" "${ST_STATE}/sbx_containers"
        echo "$2"
        ;;
    *) exit 99 ;;
esac
exit 0
STUB
    cat >"${bin}/stock-container" <<'STUB'
#!/bin/bash
printf 'stock %s\n' "$*" >>"${ST_STATE}/calls.log"
case "$1 $2" in
    "system start")
        [[ ! -e "${ST_STATE}/stock_start_fail" ]] || exit 1
        echo /usr/local/bin/container-apiserver >"${ST_STATE}/apiserver_program"
        ;;
    "system stop") rm -f "${ST_STATE}/apiserver_program" ;;
    "ls -a")
        [[ ! -e "${ST_STATE}/stock_ls_fail" ]] || exit 1
        cat "${ST_STATE}/stock_containers" 2>/dev/null || true
        ;;
    *) exit 99 ;;
esac
exit 0
STUB
    for name in "${bin}"/*; do chmod 755 "${name}"; done
}

# st_reset: the baseline world: stock services run, nothing else, plenty of space.
st_reset() {
    [[ "${ST_STATE}" == "${WORK}/"* && "${ST_ROOT}" == "${WORK}/"* ]] || return 1
    rm -rf "${ST_STATE}" "${ST_ROOT}" "${WORK}/store"
    mkdir -p "${ST_STATE}" "${ST_ROOT}"
    : >"${ST_ROOT}/.parbake-e2e-root"
    printf '%s\n' "${STOCK_PROGRAM}" >"${ST_STATE}/apiserver_program"
    echo 999999999 >"${ST_STATE}/df_kb"
    : >"${ST_STATE}/calls.log"
}

# st_script [ENV=VALUE...] -- ARGS...: the script in the stub world, with no terminal on stdin.
st_script() {
    local extra=()
    while [[ $# -gt 0 && "$1" != -- ]]; do
        extra+=("$1")
        shift
    done
    shift
    env "${ST_ENV[@]}" ${extra[@]+"${extra[@]}"} "${SCRIPT_PATH}" "$@" </dev/null
}

st_calls() { grep -Fc -- "$1" "${ST_STATE}/calls.log" || true; }

st_receipt() {
    local f
    for f in "${ST_ROOT}"/receipts/*.json; do
        [[ -f "${f}" ]] && printf '%s' "${f}" && return 0
    done
    return 1
}

st_json() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

# st_sandbox_cli: the sandbox's container CLI, as the run's step E08 would link it.
st_sandbox_cli() {
    mkdir -p "${S}/root/bin"
    cp "${ST_STUBS}/sandbox-container" "${S}/root/bin/container"
    chmod 755 "${S}/root/bin/container"
}

# st_case_prep: what E10 to E12 leave behind: S/state, the stock services stopped, the sandbox
# apiserver and the keychain item.
st_case_prep() {
    st_sandbox_cli
    record_stock_state
    if stock_running; then "${STOCK_CLI}" system stop; fi
    printf '%s\n' "${S}/ocx/packages/x/bin/container-apiserver" >"${ST_STATE}/apiserver_program"
    KEYCHAIN_OWNED=1
    : >"${ST_STATE}/keychain.${KEYCHAIN_SERVICE}"
}

st_case_ok() {
    st_case_prep
    printf 'c1\nc2\n' >"${ST_STATE}/sbx_containers"
}

st_case_fail() {
    st_case_prep
    return 1
}

st_case_wait() {
    st_case_prep
    : >"${ST_STATE}/ready"
    while :; do sleep 0.2; done
}

st_case_stubborn() {
    st_case_prep
    run_timed 120 "${S}/.out" "${S}/.err" "${ST_STUBS}/stubborn"
}

st_case_cleanfail() {
    st_case_prep
    printf 'c1\n' >"${ST_STATE}/sbx_containers"
    : >"${ST_STATE}/sbx_stop_fail"
}

st_case_zot() {
    st_case_prep
    sleep 300 &
    ZOT_PID=$!
    ZOT_BIN="/x/zot"
    printf '%s serve\n' "${ZOT_BIN}" >"${ST_STATE}/ps.${ZOT_PID}"
    printf '%s\n' "${ZOT_PID}" >"${ST_STATE}/zot_pid"
}

# --- self-test cases -------------------------------------------------------------------------

# st_expect_refused DESCRIPTION ID [ENV=VALUE...]: exit 3 and a valid refused receipt naming ID.
st_expect_refused() {
    local description="$1" id="$2" got=0 file
    shift 2
    st_script "$@" -- run >"${WORK}/out" 2>"${WORK}/err" || got=$?
    file="$(st_receipt)" || file=""
    if [[ "${got}" -eq 3 && -n "${file}" ]] && plutil -convert json -o /dev/null "${file}" 2>/dev/null &&
        [[ "$(st_json "${file}" result)" == refused && "$(st_json "${file}" refused_by)" == "${id}" ]] &&
        grep -q "^RESULT refused " "${WORK}/out" && [[ "${id}" == P04 || ! -e "${ST_ROOT}/.lock" ]]; then
        pass "${description}"
    else
        fail "${description}: exit ${got}, receipt \"${file}\""
    fi
}

self_test_refusals() {
    local ref="ghcr.io/extra-code/parbake:0.1.0"
    st_reset
    echo 26.4 >"${ST_STATE}/macos"
    st_expect_refused "P01 refuses a host that is not macOS 27" P01
    st_reset
    mv "${STUBS}/ocx" "${STUBS}/ocx.off"
    st_expect_refused "P02 refuses a missing stub tool" P02
    mv "${STUBS}/ocx.off" "${STUBS}/ocx"
    st_reset
    st_expect_refused "P02 refuses another ocx version" P02 PKG_E2E_OCX_VERSION=0.6.4
    st_reset
    st_expect_refused "P03 refuses a run without a terminal" P03 PKG_E2E_ATTENDED=0
    st_reset
    mkdir -p "${ST_ROOT}/.lock"
    echo "$$" >"${ST_ROOT}/.lock/pid"
    echo "/bin/bash /x/package-e2e.sh run" >"${ST_STATE}/ps.$$"
    st_expect_refused "P04 refuses while a live run holds the lock" P04
    st_check "the held lock stays in place" test "$(cat "${ST_ROOT}/.lock/pid")" = "$$"
    st_reset
    echo 1000 >"${ST_STATE}/df_kb"
    st_expect_refused "P05 refuses low free space" P05
    st_check "P05 names needed and free GB" grep -q "needs 60 GB" "${WORK}/err"
    st_reset
    : >"${ST_STATE}/keychain_locked"
    st_expect_refused "P06 refuses a locked keychain" P06
    st_check "P06 asks about the login keychain by path" \
        test "$(st_calls "show-keychain-info ${HOME}/Library/Keychains/login.keychain-db")" -ge 1
    st_reset
    : >"${ST_STATE}/keychain_any"
    st_expect_refused "P07 refuses an existing keychain item" P07
    st_reset
    echo "/opt/other/bin/container-apiserver" >"${ST_STATE}/apiserver_program"
    st_expect_refused "P08 refuses a foreign apiserver program" P08
    st_reset
    echo "${ST_ROOT}/20260101T000000Z-abcdef12/ocx/packages/x/bin/container-apiserver" >"${ST_STATE}/apiserver_program"
    st_expect_refused "P08 refuses an apiserver under PKG_E2E_ROOT" P08
    st_check "P08 names run --recover" grep -q -- "--recover" "${WORK}/err"
    st_reset
    echo "c-stock" >"${ST_STATE}/stock_containers"
    st_expect_refused "P09 refuses when a stock container exists" P09
    st_check "the P09 refusal changed nothing" test "$(st_calls "system stop")" = 0
    st_reset
    echo "${ref}" >"${ST_STATE}/ocx_missing"
    st_expect_refused "P10 refuses an unresolved reference" P10 PKG_E2E_PARBAKE_REF="${ref}"
    st_check "security is only asked for attributes" test "$(grep -Ec 'security .* -(w|g)( |$)' "${ST_STATE}/calls.log" || true)" = 0
}

# st_expect_run DESCRIPTION CASE WANT_EXIT [ENV=VALUE...]: runs CASE; sets ST_FILE to the receipt.
st_expect_run() {
    local description="$1" case_name="$2" want="$3" got=0 envs=() args=()
    shift 3
    while [[ $# -gt 0 && "$1" != -- ]]; do
        envs+=("$1")
        shift
    done
    [[ $# -eq 0 ]] || shift
    args=("$@")
    st_script _PKG_E2E_SELFTEST_CASE="${case_name}" ${envs[@]+"${envs[@]}"} -- run ${args[@]+"${args[@]}"} >"${WORK}/out" 2>"${WORK}/err" || got=$?
    ST_FILE="$(st_receipt)" || ST_FILE=""
    if [[ "${got}" -eq "${want}" && -n "${ST_FILE}" ]] && plutil -convert json -o /dev/null "${ST_FILE}" 2>/dev/null; then
        pass "${description}"
    else
        fail "${description}: exit ${got}, want ${want}"
        tail -n 4 "${WORK}/err" >&2
    fi
}

st_check() {
    local description="$1"
    shift
    if "$@"; then pass "${description}"; else fail "${description}"; fi
}

# st_leftovers: ST_ROOT holds nothing but the receipts and the root marker (no sandbox, lock or stale lock).
st_leftovers() {
    local name
    while IFS= read -r name; do
        case "${name}" in
            receipts | .parbake-e2e-root) ;;
            *) return 1 ;;
        esac
    done < <(ls -A "${ST_ROOT}")
}

self_test_cleanup() {
    local kept
    st_reset
    st_expect_run "a stubbed run that passes cleans up and exits 0" ok 0
    st_check "the receipt says pass with the cleanup object" \
        test "$(st_json "${ST_FILE}" result)" = pass -a "$(st_json "${ST_FILE}" cleanup.stock_restored)" = true -a "$(st_json "${ST_FILE}" cleanup.sandbox_removed)" = true
    st_check "the output ends with the RESULT line" grep -q "^RESULT pass ${ST_ROOT}/receipts/" "${WORK}/out"
    st_check "the stock services started once and run again" test "$(st_calls "stock system start")" = 1 -a "$(<"${ST_STATE}/apiserver_program")" = "${STOCK_PROGRAM}"
    st_check "the sandbox containers were removed and its services stopped" test "$(st_calls "sandbox rm -f")" = 2 -a "$(st_calls "sandbox system stop")" = 1
    st_check "the keychain item is gone" test ! -e "${ST_STATE}/keychain.container-runtime-macos.e2e.$(st_json "${ST_FILE}" run_id)"
    st_check "the sandbox, the lock and the stale lock are gone" st_leftovers
    st_check "the receipt is mode 600" test "$(stat -f %Lp "${ST_FILE}")" = 600

    st_reset
    st_expect_run "a failing step still cleans up and exits 1" fail 1
    st_check "the failed run restored the stock services and says fail" \
        test "$(st_calls "stock system start")" = 1 -a "$(st_json "${ST_FILE}" result)" = fail -a "$(st_json "${ST_FILE}" exit)" = 1

    st_reset
    st_reset
    : >"${ST_STATE}/stock_start_fail"
    st_expect_run "a failed stock restart exits 4" ok 4
    st_check "the receipt says stock_restored false" test "$(st_json "${ST_FILE}" cleanup.stock_restored)" = false
    st_check "the message names the command to run by hand" grep -q "system start" "${WORK}/err"
    st_check "a failed restart does not skip the sandbox removal" test "$(st_json "${ST_FILE}" cleanup.sandbox_removed)" = true

    st_reset
    rm -f "${ST_STATE}/apiserver_program"
    st_expect_run "stock_ran=0 passes" ok 0
    st_check "stock_ran=0 leaves the stock services stopped" test "$(st_calls "stock system start")" = 0 -a ! -e "${ST_STATE}/apiserver_program"
    st_check "the receipt records stock_restored null" test "$(st_json "${ST_FILE}" cleanup.stock_restored)" = null -o -z "$(st_json "${ST_FILE}" cleanup.stock_restored)"

    st_reset
    st_expect_run "a failing cleanup action exits 4" cleanfail 4
    st_check "a failing action does not stop the later ones" \
        test "$(st_calls "stock system start")" = 1 -a "$(st_json "${ST_FILE}" cleanup.keychain_item_removed)" = true

    st_reset
    rm -f "${ST_STATE}/apiserver_program"
    st_expect_run "a sandbox whose apiserver does not stop is kept and exits 4" cleanfail 4
    st_check "the sandbox stayed and the receipt says so" \
        test "$(st_json "${ST_FILE}" cleanup.sandbox_removed)" = false -a -d "${ST_ROOT}/$(st_json "${ST_FILE}" run_id)"
    st_check "the message names run --recover" grep -q -- "run --recover" "${WORK}/err"

    st_reset
    rm -f "${ST_STATE}/apiserver_program"
    : >"${ST_STATE}/sbx_stop_hang"
    st_expect_run "a hung sandbox stop is killed at its time limit and cleanup goes on" ok 4
    st_check "the hung stop left the sandbox in place and the keychain item gone" \
        test "$(st_json "${ST_FILE}" cleanup.sandbox_removed)" = false -a "$(st_json "${ST_FILE}" cleanup.keychain_item_removed)" = true

    st_reset
    rm -rf "${ST_ROOT}"
    st_expect_run "a run under a missing root creates it and removes the sandbox" ok 0
    st_check "the run created the root marker and a mode 700 receipts directory" \
        test -e "${ST_ROOT}/.parbake-e2e-root" -a "$(stat -f %Lp "${ST_ROOT}/receipts")" = 700

    st_reset
    st_expect_run "a run with a local registry stops it by its PID" zot 0
    st_check "the recorded zot process is gone" st_zot_gone
    st_check "the receipt says zot_stopped" test "$(st_json "${ST_FILE}" cleanup.zot_stopped)" = true

    st_reset
    kept=0
    st_script _PKG_E2E_SELFTEST_CASE=ok -- run --keep >"${WORK}/out" 2>"${WORK}/err" || kept=$?
    st_check "--keep passes" test "${kept}" = 0
    ST_FILE="$(st_receipt)" || ST_FILE=""
    st_check "--keep leaves the sandbox, still restores the stock services and says sandbox_removed null" \
        test -d "${ST_ROOT}/$(st_json "${ST_FILE}" run_id)/key" -a "$(st_calls "stock system start")" = 1 -a -z "$(st_json "${ST_FILE}" cleanup.sandbox_removed)"
    st_check "--keep names the private key" grep -q "holds a private key" "${WORK}/out"
    st_check "--keep rewrites S/state to stock_ran=0" grep -qx 'stock_ran=0' "${ST_ROOT}/$(st_json "${ST_FILE}" run_id)/state"
    st_check "the sandbox holds bundle/ and no pre-made VM.bundle" \
        test -d "${ST_ROOT}/$(st_json "${ST_FILE}" run_id)/bundle" -a ! -e "${ST_ROOT}/$(st_json "${ST_FILE}" run_id)/bundle/VM.bundle"
}

st_zot_gone() {
    local pid
    pid="$(cat "${ST_STATE}/zot_pid")"
    ! kill -0 "${pid}" 2>/dev/null
}

# st_signal_case SIGNAL WANT [CASE]: SIGNAL during the long step runs cleanup once and exits WANT.
st_signal_case() {
    local sig="$1" want="$2" case_name="${3:-wait}" pid got=0 waited=0
    st_reset
    set -m
    env "${ST_ENV[@]}" _PKG_E2E_SELFTEST_CASE="${case_name}" "${SCRIPT_PATH}" run </dev/null >"${WORK}/out" 2>"${WORK}/err" &
    pid=$!
    while [[ ! -e "${ST_STATE}/ready" && "${waited}" -lt 100 ]]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    kill -s "${sig}" "${pid}"
    wait "${pid}" || got=$?
    set +m
    ST_FILE="$(st_receipt)" || ST_FILE=""
    if [[ "${got}" -eq "${want}" && "$(st_calls "stock system start")" -eq 1 && "$(st_calls "sandbox system stop")" -eq 1 &&
    "$(st_json "${ST_FILE}" result)" == fail && "$(st_json "${ST_FILE}" exit)" == "${want}" ]] && st_leftovers; then
        pass "SIG${sig} during a ${case_name} step runs cleanup once, restores the stock services and exits ${want}"
    else
        fail "SIG${sig} during a ${case_name} step: exit ${got}, want ${want}"
    fi
}

# st_stubborn_gone: the step's TERM-ignoring process and its child are both gone.
st_stubborn_gone() {
    local f pid
    for f in stubborn_pid stubborn_child; do
        pid="$(cat "${ST_STATE}/${f}" 2>/dev/null)" || return 1
        ! pid_alive "${pid}" || return 1
    done
}

# st_lock_race: a stale lock whose directory names another PID after the move is handed back.
st_lock_race() {
    (
        ROOT="${ST_ROOT}"
        RUN_ID=20260101T000000Z-abcdef12
        mkdir -p "${ROOT}/.lock"
        echo 424242 >"${ROOT}/.lock/pid"
        mv() { command mv "$@" && printf '999\n' >"$2/pid"; }
        if acquire_lock 2>/dev/null; then exit 1; fi
        [[ "$(cat "${ROOT}/.lock/pid")" == 999 && "${REFUSED_BY}" == P04 && ! -e "${ROOT}/.lock.stale.${RUN_ID}" ]]
    )
}

self_test_locks() {
    st_reset
    mkdir -p "${ST_ROOT}/.lock"
    echo 424242 >"${ST_ROOT}/.lock/pid"
    st_expect_run "a stale lock is taken over" ok 0
    st_check "the takeover is announced and leaves no lock" grep -q "took over a stale lock" "${WORK}/err"
    st_check "no .lock.stale directory remains" st_leftovers
    st_reset
    mkdir -p "${ST_ROOT}/.lock"
    echo "$$" >"${ST_ROOT}/.lock/pid"
    echo "vim notes.txt" >"${ST_STATE}/ps.$$"
    st_expect_run "a lock whose PID runs another program is stale" ok 0
    st_reset
    mkdir -p "${ST_ROOT}/.lock"
    st_expect_refused "a lock without a PID refuses" P04
    st_reset
    st_check "a lock that changes hands during the takeover is handed back and refused" st_lock_race
}

self_test_guarded() {
    local base="${ST_ROOT}" id=20260101T000000Z-abcdef12 store="${WORK}/store"
    st_reset
    mkdir -p "${base}/${id}/link" "${base}/${id}/root" "${store}/content"
    echo keep >"${store}/content/file"
    ln -s "${store}/content" "${base}/${id}/link/container"
    ln -s "${store}/content" "${base}/${id}/root/bin"
    expect_code "the remover refuses /" 1 remove_sandbox / "${id}" "/${id}"
    expect_code "the remover refuses \$HOME" 1 remove_sandbox "${HOME}" "${id}" "${HOME}/${id}"
    expect_code "the remover refuses PKG_E2E_ROOT itself" 1 remove_sandbox "${base}" "${id}" "${base}"
    expect_code "the remover refuses a malformed run id" 1 remove_sandbox "${base}" "../x" "${base}/../x"
    expect_code "the remover refuses an id that does not match the path" 1 remove_sandbox "${base}" "${id}" "${base}/20260101T000000Z-00000000"
    ln -s "${base}/${id}" "${base}/20260202T000000Z-abcdef12"
    expect_code "the remover refuses a symlinked sandbox" 1 remove_sandbox "${base}" 20260202T000000Z-abcdef12 "${base}/20260202T000000Z-abcdef12"
    st_check "the refusals left the sandbox in place" test -d "${base}/${id}/link"
    expect_ok "the remover removes a sandbox with symlinks" remove_sandbox "${base}" "${id}" "${base}/${id}"
    st_check "the symlinks are gone and the store is intact" test ! -e "${base}/${id}" -a "$(<"${store}/content/file")" = keep

    local good="container-runtime-macos.e2e.${id}"
    expect_code "the keychain deleter refuses the guest service" 1 delete_run_keychain_item container-runtime-macos.guest
    expect_code "the keychain deleter refuses a prefix" 1 delete_run_keychain_item container-runtime-macos.e2e.
    expect_code "the keychain deleter refuses a malformed id" 1 delete_run_keychain_item container-runtime-macos.e2e.2026-abc
    expect_code "the keychain deleter refuses an empty service" 1 delete_run_keychain_item ""
    st_check "the refusals made no keychain call" test "$(st_calls "delete-generic-password")" = 0
    : >"${ST_STATE}/keychain.${good}"
    expect_ok "the keychain deleter deletes the run's item" delete_run_keychain_item "${good}"
    st_check "it deleted exactly that item with the account" test "$(st_calls "delete-generic-password -s ${good} -a ci")" = 1
}

self_test_recover() {
    local id=20260101T000000Z-abcdef12 sandbox
    sandbox="${ST_ROOT}/${id}"
    st_reset
    mkdir -p "${sandbox}/root/bin" "${ST_ROOT}/receipts"
    S="${sandbox}"
    st_sandbox_cli
    printf 'stock_ran=1\n' >"${sandbox}/state"
    printf '%s\n' "${sandbox}/ocx/packages/x/bin/container-apiserver" >"${ST_STATE}/apiserver_program"
    : >"${ST_STATE}/keychain.container-runtime-macos.e2e.${id}"
    expect_ok "--recover exits 0" st_script -- run --recover
    st_check "--recover stopped the sandbox apiserver, restarted the stock services and removed the sandbox" \
        test "$(st_calls "sandbox system stop")" = 1 -a "$(st_calls "stock system start")" = 1 -a ! -e "${sandbox}" -a "$(<"${ST_STATE}/apiserver_program")" = "${STOCK_PROGRAM}"
    st_check "--recover deleted the leftover keychain item" test ! -e "${ST_STATE}/keychain.container-runtime-macos.e2e.${id}"
    st_check "--recover releases the lock" test ! -e "${ST_ROOT}/.lock"

    st_reset
    mkdir -p "${sandbox}/root/bin" "${ST_ROOT}/receipts"
    S="${sandbox}"
    st_sandbox_cli
    printf 'stock_ran=1\n' >"${sandbox}/state"
    printf '%s\n' "${sandbox}/ocx/packages/x/bin/container-apiserver" >"${ST_STATE}/apiserver_program"
    : >"${ST_STATE}/sbx_stop_fail"
    expect_code "--recover exits 4 when the sandbox apiserver does not stop" 4 st_script -- run --recover
    st_check "--recover kept that sandbox and did not restart the stock services" \
        test -d "${sandbox}" -a "$(st_calls "stock system start")" = 0

    st_reset
    mkdir -p "${sandbox}"
    printf 'stock_ran=0\n' >"${sandbox}/state"
    rm -f "${ST_STATE}/apiserver_program"
    expect_ok "--recover without services exits 0" st_script -- run --recover
    st_check "--recover leaves stopped stock services stopped" test "$(st_calls "system start")" = 0 -a ! -e "${sandbox}"

    st_reset
    mkdir -p "${sandbox}"
    echo "/opt/other/bin/container-apiserver" >"${ST_STATE}/apiserver_program"
    expect_code "--recover refuses a foreign apiserver" 3 st_script -- run --recover
    st_check "--recover touched nothing of the foreign setup" test "$(st_calls "system stop")" = 0 -a -d "${sandbox}"
}

# st_steps_ok FILE: the fifteen published-mode steps passed and E05 was skipped.
st_steps_ok() {
    local i
    for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        [[ "${i}" != 4 ]] || continue
        [[ "$(st_json "$1" "steps.${i}.result")" == pass ]] || return 1
    done
    [[ "$(st_json "$1" steps.4.result)" == skip ]]
}

# st_insecure_scoped: the insecure variable is set on exactly the ocx calls that name the local registry.
st_insecure_scoped() {
    local set_n named_n
    set_n="$(grep -c 'insecure=127\.0\.0\.1:' "${ST_STATE}/ocx_env.log" || true)"
    named_n="$(grep -c '| .*127\.0\.0\.1:' "${ST_STATE}/ocx_env.log" || true)"
    [[ "${set_n}" -gt 0 && "${set_n}" -eq "${named_n}" ]]
}

st_trust_matches() { cmp -s <(doc_policy_block) "${ST_STATE}/trust.copy"; }

st_mkpkg() {
    mkdir -p "${WORK}/pkg"
    : >"${WORK}/pkg/parbake-1.2.3.tar.xz"
    : >"${WORK}/pkg/parbake-1.2.3-metadata.json"
    : >"${WORK}/pkg/container-9.tar.xz"
    : >"${WORK}/pkg/container-9-metadata.json"
}

self_test_steps() {
    local id
    st_reset
    st_expect_run "a full stubbed published run passes" "" 0
    st_check "every published-mode step passes and E05 is skipped" st_steps_ok "${ST_FILE}"
    id="$(st_json "${ST_FILE}" run_id)"
    st_check "the receipt has result pass, mode published, exit 0 and a script commit" \
        test "$(st_json "${ST_FILE}" result)" = pass -a "$(st_json "${ST_FILE}" mode)" = published -a "$(st_json "${ST_FILE}" exit)" = 0 -a -n "$(st_json "${ST_FILE}" script_commit)"
    st_check "the receipt names host, ocx and guest versions" \
        test "$(st_json "${ST_FILE}" host.macos)" = 27.0 -a "$(st_json "${ST_FILE}" host.arch)" = arm64 -a "$(st_json "${ST_FILE}" ocx)" = 0.6.5 -a "$(st_json "${ST_FILE}" guest.macos)" = 27.0
    st_check "both packages carry a digest and verified true" \
        test "$(st_json "${ST_FILE}" packages.container.verified)" = true -a "$(st_json "${ST_FILE}" packages.parbake.verified)" = true
    st_check "the digests are sha256 values" \
        test "$(st_json "${ST_FILE}" packages.container.digest | cut -c1-7)" = sha256: -a "$(st_json "${ST_FILE}" packages.parbake.digest | cut -c1-7)" = sha256:
    st_check "the steps used the digest-pinned references" \
        grep -q "package install --link .*/link/plugin ghcr.io/extra-code/parbake:.*@sha256:" "${ST_STATE}/calls.log"
    st_check "the receipt holds no home path" test "$(grep -cF "${HOME}" "${ST_FILE}" || true)" = 0
    st_check "the policy written at E01 is the quickstart's block" st_trust_matches
    st_check "OCX_INSECURE_REGISTRIES never reaches a published-mode call" test "$(grep -c 'insecure=[^ ]' "${ST_STATE}/ocx_env.log" || true)" = 0
    st_check "every ocx call of the steps runs in the sandbox home with the hermetic variables" \
        test "$(grep 'package' "${ST_STATE}/ocx_env.log" | grep -vc "home=${ST_ROOT}/${id}/ocx insecure= nocfg=1 noproj=1 docker=${ST_ROOT}/${id}/docker" || true)" = 0
    st_check "the P10 lookup uses a scratch home, not the user's" \
        test "$(grep 'index list' "${ST_STATE}/ocx_env.log" | grep -c "home=${HOME}" || true)" = 0 -a "$(grep -c 'index list' "${ST_STATE}/ocx_env.log")" -ge 2
    st_check "the pull token never reaches a command line" test "$(grep -c tok123 "${ST_STATE}/calls.log" || true)" = 0
    st_check "the sandbox is gone" st_leftovers
    st_check "the verify steps ask for JSON output" grep -q -- "--format json package verify" "${ST_STATE}/calls.log"
    st_check "every curl call starts with -q" \
        test "$(grep -c '^curl ' "${ST_STATE}/calls.log")" -gt 0 -a "$(grep '^curl ' "${ST_STATE}/calls.log" | grep -vc '^curl -q ' || true)" = 0

    st_reset
    : >"${ST_STATE}/sbx_program_unresolved"
    st_expect_run "E11 accepts the unresolved apiserver path under the sandbox root" "" 0

    st_reset
    : >"${ST_STATE}/create_locked"
    st_expect_run "parbake create exit 69 fails E12" "" 1
    st_check "E12 names the locked keychain" \
        test "$(st_json "${ST_FILE}" steps.11.result)" = fail -a "$(st_json "${ST_FILE}" steps.11.detail | grep -c 'keychain is locked')" = 1

    st_reset
    : >"${ST_STATE}/verify_bad_identity"
    st_expect_run "a signature with another identity fails E02" "" 1
    st_check "E02 failed as a product failure" \
        test "$(st_json "${ST_FILE}" steps.1.result)" = fail -a "$(st_json "${ST_FILE}" steps.1.detail | cut -c1-8)" = product:

    st_reset
    : >"${ST_STATE}/verify_msg_other"
    st_expect_run "exit 77 without the identity mismatch message fails E04" "" 1
    st_check "E04 failed as a product failure" \
        test "$(st_json "${ST_FILE}" steps.3.result)" = fail -a "$(st_json "${ST_FILE}" steps.3.detail | cut -c1-8)" = product:

    st_reset
    st_expect_run "a run with inherited OCX variables passes" "" 0 OCX_HOME=/leak/home OCX_INSECURE_REGISTRIES=leak:1 DOCKER_CONFIG=/leak/docker OCX_CONFIG=/leak/config
    st_check "no ocx call saw an inherited OCX or Docker variable" test "$(grep -c leak "${ST_STATE}/ocx_env.log" || true)" = 0

    st_reset
    echo 1 >"${ST_STATE}/install_net_fail"
    st_expect_run "a network failure on install is retried once and passes" "" 0
    st_check "the retried install ran twice for E06" test "$(wc -l <"${ST_STATE}/install_count" | tr -d ' ')" = 3

    st_reset
    echo 9 >"${ST_STATE}/install_net_fail"
    st_expect_run "a network failure that persists fails E06 after one retry" "" 1
    st_check "the install ran twice, failed as network and the sandbox is gone" \
        test "$(wc -l <"${ST_STATE}/install_count" | tr -d ' ')" = 2 -a "$(st_json "${ST_FILE}" steps.5.result)" = fail -a "$(st_json "${ST_FILE}" steps.5.detail | cut -c1-8)" = network:
    st_check "nothing of the run is left behind" st_leftovers

    st_reset
    : >"${ST_STATE}/ocx_unverified"
    st_expect_run "no trust policy covers in a published install fails E06" "" 1
    st_check "the failed E06 is a product failure and cleanup ran" \
        test "$(st_json "${ST_FILE}" steps.5.result)" = fail -a "$(st_json "${ST_FILE}" steps.5.detail | cut -c1-8)" = product: -a "$(st_json "${ST_FILE}" result)" = fail
    st_check "nothing of the run is left behind" st_leftovers

    st_reset
    : >"${ST_STATE}/install_leak"
    st_expect_run "an install failure with quotes, tabs and a bearer header stays valid JSON" "" 1
    st_check "the detail keeps the quotes and drops the token lines" \
        grep -q 'bad \\"quote\\"' "${ST_FILE}"
    st_check "no Authorization or Bearer text reaches the receipt" test "$(grep -ciE 'authorization|bearer' "${ST_FILE}" || true)" = 0

    st_reset
    echo created >"${ST_STATE}/sbx_row_state"
    st_expect_run "a container that never runs times out at E14" "" 1 PKG_E2E_RUN_TIMEOUT=1
    st_check "E14 failed as timeout, cleanup restored the stock services and stopped the sandbox" \
        test "$(st_json "${ST_FILE}" steps.13.result)" = fail -a "$(st_json "${ST_FILE}" steps.13.detail | cut -c1-8)" = timeout: -a "$(st_calls "stock system start")" = 1 -a "$(st_calls "sandbox system stop")" = 1 -a "$(st_json "${ST_FILE}" cleanup.stock_restored)" = true

    st_reset
    echo 4 >"${ST_STATE}/ocx_sleep"
    st_expect_run "a run past the total timeout fails the current step" "" 1 PKG_E2E_TOTAL_TIMEOUT=2
    st_check "the failing step is a timeout naming the total" \
        test "$(grep -c '"detail": "timeout: the total timeout' "${ST_FILE}" || true)" = 1
    st_check "nothing of the run is left behind" st_leftovers

    st_reset
    : >"${ST_STATE}/curl_fail"
    st_expect_refused "P10 refuses a reference whose digest cannot be read" P10
    st_reset
    : >"${ST_STATE}/curl_nodigest"
    st_expect_refused "P10 refuses a registry answer without a digest" P10

    st_reset
    st_mkpkg
    st_expect_run "a full stubbed candidate run passes" "" 0 -- --candidate 1.2.3
    st_check "the candidate receipt is mode candidate, unsigned and every step passes or skips" \
        test "$(st_json "${ST_FILE}" mode)" = candidate -a "$(st_json "${ST_FILE}" packages.parbake.verified)" = false -a "$(st_json "${ST_FILE}" steps.4.result)" = pass -a "$(st_json "${ST_FILE}" steps.1.result)" = skip -a "$(st_json "${ST_FILE}" steps.2.result)" = skip -a "$(st_json "${ST_FILE}" steps.3.result)" = skip
    st_check "the candidate Parbake comes from the local registry by digest" \
        test "$(st_json "${ST_FILE}" packages.parbake.ref | cut -c1-10)" = 127.0.0.1: -a "$(st_json "${ST_FILE}" packages.parbake.digest | cut -c1-7)" = sha256:
    st_check "the published container is installed with a covering policy" \
        test "$(st_json "${ST_FILE}" packages.container.verified)" = true -a "$(st_json "${ST_FILE}" packages.container.ref | cut -c1-9)" = ghcr.io/e
    st_check "the insecure variable is set on exactly the local-registry calls" st_insecure_scoped
    st_check "the candidate pushes use -- before the archive" grep -q -- "package push .* -- " "${ST_STATE}/calls.log"
    st_check "zot is stopped and the sandbox is gone" st_zot_gone
    st_check "zot_stopped is true in the receipt" test "$(st_json "${ST_FILE}" cleanup.zot_stopped)" = true

    st_reset
    st_mkpkg
    st_expect_run "a candidate run with a container archive pushes both" "" 0 PKG_E2E_CONTAINER_ARCHIVE="${WORK}/pkg/container-9.tar.xz" -- --candidate 1.2.3
    st_check "both pushes ran and the container is unverified" \
        test "$(st_calls "package push")" = 2 -a "$(st_json "${ST_FILE}" packages.container.verified)" = false -a "$(st_json "${ST_FILE}" packages.container.ref | cut -c1-10)" = 127.0.0.1:
    st_check "the insecure variable is still scoped to the local registry" st_insecure_scoped

    st_reset
    st_mkpkg
    cd "${WORK}/pkg"
    st_expect_run "a relative container archive path is made absolute" "" 0 PKG_E2E_CONTAINER_ARCHIVE=container-9.tar.xz -- --candidate 1.2.3
    cd "${WORK}"
    st_check "the push got the absolute archive path" grep -q -- "-- ${WORK}/pkg/container-9.tar.xz" "${ST_STATE}/calls.log"

    st_reset
    st_mkpkg
    echo 3 >"${ST_STATE}/verify_cand_rc"
    st_expect_run "an unexpected verify exit on the unsigned candidate is a warn and the run passes" "" 0 -- --candidate 1.2.3
    st_check "E05 is a warn that names the exit code" \
        test "$(st_json "${ST_FILE}" steps.4.result)" = warn -a "$(st_json "${ST_FILE}" steps.4.detail | grep -c 'exited 3')" = 1 -a "$(st_json "${ST_FILE}" result)" = pass

    st_reset
    st_mkpkg
    echo 0 >"${ST_STATE}/verify_cand_rc"
    st_expect_run "a candidate that verifies is a warn" "" 0 -- --candidate 1.2.3
    st_check "a local-registry package is never reported as verified" test "$(st_json "${ST_FILE}" packages.parbake.verified)" = false

    st_reset
    st_mkpkg
    : >"${ST_STATE}/zot_fail"
    st_expect_run "a zot start failure fails E05" "" 1 -- --candidate 1.2.3
    st_check "E05 failed, the sandbox is gone and the stock services were never stopped" \
        test "$(st_json "${ST_FILE}" steps.4.result)" = fail -a "$(st_calls "stock system stop")" = 0
    st_check "nothing of the run is left behind" st_leftovers

    st_reset
    expect_code "a candidate without its archive exits 2" 2 st_script -- run --candidate 9.9.9
    st_mkpkg
    rm "${WORK}/pkg/container-9-metadata.json"
    expect_code "a container archive without its metadata exits 2" 2 st_script PKG_E2E_CONTAINER_ARCHIVE="${WORK}/pkg/container-9.tar.xz" -- run --candidate 1.2.3
}

self_test_taskfile() {
    local out
    if [[ -z "${E2E_TASK}" ]]; then
        printf 'self-test skipped: task is not installed, the Taskfile case needs it\n'
        return 0
    fi
    out="$(cd "${REPO_ROOT}" && "${E2E_TASK}" --list-all 2>&1)" || {
        fail "task --list-all failed"
        return 0
    }
    if grep -q 'e2e:package:' <<<"${out}" && grep -q 'e2e:package:candidate' <<<"${out}" && grep -q 'lint:e2e' <<<"${out}"; then
        pass "task --list-all names e2e:package, e2e:package:candidate and lint:e2e"
    else
        fail "task --list-all misses an e2e task"
    fi
}

self_test_json() {
    local raw out
    raw=$'a"b\\c\nd\te'
    out="$(json_str "${raw}")"
    st_check "json_str escapes quotes, backslashes and newlines" test "${out}" = '"a\"b\\c\nd\te"'
    printf '{"k": %s}\n' "${out}" >"${WORK}/j.json"
    expect_ok "json_str output is valid JSON" plutil -convert json -o /dev/null "${WORK}/j.json"
    st_check "filter_msg drops credential lines and joins the rest" \
        test "$(filter_msg <<<$'a "b"\nAuthorization: Bearer abc\nc')" = 'a "b" | c'
    st_check "json_str writes the home directory as ~" test "$(json_str "${HOME}/x")" = '"~/x"'
    st_check "json_str writes the bare home directory as ~" test "$(json_str "${HOME}")" = '"~"'
    st_check "json_str leaves a longer directory name alone" test "$(json_str "${HOME}2/x")" = "\"${HOME}2/x\""
    raw="$(printf 'a%.0s' $(seq 399))é"
    out="$(filter_msg <<<"${raw}")"
    st_check "filter_msg cuts at 400 bytes without a partial UTF-8 sequence" \
        test "$(printf '%s' "${out}" | wc -c | tr -d ' ')" -le 400 -a "${#out}" -ge 399
    printf '%s' "${out}" >"${WORK}/utf8"
    expect_ok "the cut message is valid UTF-8" iconv -f UTF-8 -t UTF-8 "${WORK}/utf8"
}

# st_hooks_probe MODE: hygiene and init_tools in a subshell with the self-test hooks set; prints nothing
# and exits 0 when the real tool paths are in force and the hooks are unset (MODE bad) or honoured (MODE good).
st_hooks_probe() {
    (
        _PKG_E2E_SELFTEST_BIN="${STUBS}"
        _PKG_E2E_SELFTEST_CASE=ok
        _PKG_E2E_SELFTEST_PKGDIR="${WORK}/pkg"
        _PKG_E2E_SELFTEST_OTHER=1
        case "$1" in
            wrong) _PKG_E2E_SELFTEST_NONCE=00000000000000000000000000000000 ;;
            nofile) _PKG_E2E_SELFTEST_NONCEFILE="${WORK}/none" ;;
            good) ;;
        esac
        export _PKG_E2E_SELFTEST_BIN _PKG_E2E_SELFTEST_CASE _PKG_E2E_SELFTEST_PKGDIR _PKG_E2E_SELFTEST_OTHER _PKG_E2E_SELFTEST_NONCE _PKG_E2E_SELFTEST_NONCEFILE
        hygiene
        init_tools
        if [[ "$1" == good ]]; then
            [[ "${T_SECURITY}" == "${STUBS}/security" && "${_PKG_E2E_SELFTEST_CASE:-}" == ok ]]
        else
            [[ "${T_SECURITY}" == /usr/bin/security && "${T_CURL}" == /usr/bin/curl && "${PACKAGE_DIR}" == "${REPO_ROOT}/.build/package" &&
                -z "${_PKG_E2E_SELFTEST_BIN:-}" && -z "${_PKG_E2E_SELFTEST_CASE:-}" && -z "${_PKG_E2E_SELFTEST_OTHER:-}" ]] &&
                ! selftest_hooks_valid
        fi
    )
}

# st_class TEXT: the class cap_class gives a failed capture whose stderr is TEXT.
st_class() {
    CAP_RC=1
    CAP_OUT=""
    CAP_ERR="$1"
    cap_class
}

st_apiserver_quiet() {
    (
        ROOT="${ST_ROOT}"
        no_apiserver_under_root
    )
}

self_test_hardening() {
    st_check "init_tools ignores every self-test hook when the nonce is wrong" st_hooks_probe wrong
    st_check "init_tools ignores every self-test hook when the nonce file is missing" st_hooks_probe nofile
    st_check "init_tools honours the hooks with the right nonce file" st_hooks_probe good
    st_check "a bare registry operation failure is a product failure" test "$(st_class 'error: registry operation failed: blob unknown')" = product
    st_check "the substring ssl inside a word is not a network failure" test "$(st_class 'classless failure')" = product
    st_check "connection reset is a network failure" test "$(st_class 'error: connection reset by peer')" = network
    st_check "a TLS handshake failure is a network failure" test "$(st_class 'tls handshake timeout')" = network
    st_check "the GHCR referrers 401 is a network failure" test "$(st_class 'Not authorized: url https://ghcr.io/v2/extra-code/parbake/referrers/sha256:ab')" = network
    st_check "another not authorized is a product failure" test "$(st_class 'Not authorized: url https://ghcr.io/v2/extra-code/parbake/manifests/x')" = product
    st_reset
    st_check "launchctl without a service counts as quiet" st_apiserver_quiet
    printf '%s\n' "${STOCK_PROGRAM}" >"${ST_STATE}/apiserver_program"
    st_check "the stock apiserver counts as quiet" st_apiserver_quiet
    printf '%s\n' "${ST_ROOT}/20260101T000000Z-abcdef12/ocx/packages/x/bin/container-apiserver" >"${ST_STATE}/apiserver_program"
    st_check "a sandbox apiserver is not quiet" test "$(st_apiserver_quiet && echo yes || echo no)" = no
    rm -f "${ST_STATE}/apiserver_program"
    : >"${ST_STATE}/launchctl_error"
    st_check "a launchctl error is not quiet" test "$(st_apiserver_quiet && echo yes || echo no)" = no
    st_reset
}

self_test_kit() {
    local tmp nonce
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/package-e2e-selftest.XXXXXX")" || die "cannot create the self-test directory" || return 1
    WORK="$(cd -P "${tmp}" && pwd -P)" || die "cannot resolve ${tmp}" || return 1
    [[ -n "${WORK}" && -d "${WORK}" ]] || die "the self-test directory is empty" || return 1
    trap 'rm -rf "${WORK}"' EXIT
    nonce="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s' "${nonce}" >"${WORK}/nonce"
    HOME="${WORK}/home"
    mkdir -p "${HOME}"
    export HOME
    ST_ROOT="${HOME}/.parbake-e2e"
    ST_STATE="${WORK}/state"
    STUBS="${WORK}/stubs"
    st_write_stubs
    ST_ENV=("HOME=${HOME}" "PKG_E2E_ROOT=${ST_ROOT}" "PKG_E2E_ATTENDED=1" "_PKG_E2E_SELFTEST_BIN=${STUBS}" "ST_STATE=${ST_STATE}" "ST_STUBS=${STUBS}" "_PKG_E2E_SELFTEST_PKGDIR=${WORK}/pkg"
        "_PKG_E2E_SELFTEST_NONCE=${nonce}" "_PKG_E2E_SELFTEST_NONCEFILE=${WORK}/nonce")
    export ST_STATE ST_STUBS="${STUBS}"
    _PKG_E2E_SELFTEST_BIN="${STUBS}" _PKG_E2E_SELFTEST_NONCE="${nonce}" _PKG_E2E_SELFTEST_NONCEFILE="${WORK}/nonce"
    export _PKG_E2E_SELFTEST_BIN _PKG_E2E_SELFTEST_NONCE _PKG_E2E_SELFTEST_NONCEFILE
    init_tools
    st_reset
}

self_test() {
    local before after
    self_test_kit || return 1
    before="$(repo_state)"
    self_test_usage
    self_test_constants
    self_test_params
    self_test_docs
    self_test_json
    self_test_hardening
    self_test_refusals
    self_test_cleanup
    self_test_steps
    self_test_taskfile
    st_signal_case INT 130
    st_signal_case TERM 143
    st_signal_case HUP 129
    st_signal_case PIPE 141
    st_signal_case QUIT 131
    st_signal_case INT 130 stubborn
    st_check "an interrupt during a step whose child ignores TERM leaves no process behind" st_stubborn_gone
    self_test_locks
    self_test_guarded
    self_test_recover
    after="$(repo_state)"
    if [[ "${before}" == "${after}" ]]; then
        pass "the self-test leaves the untracked files as they were"
    else
        fail "the self-test changed the untracked files"
    fi
    if [[ "${STATUS}" -eq 0 ]]; then
        printf 'package-e2e.sh self-test passed\n'
    fi
    return "${STATUS}"
}

main() {
    hygiene
    init_tools
    case "${1:-}" in
        --self-test) self_test ;;
        -h | --help) usage ;;
        run)
            shift
            run "$@"
            ;;
        "") usage_error "no subcommand" ;;
        *) usage_error "unknown option \"$1\"" ;;
    esac
}

main "$@"
