#!/bin/bash
# SPDX-FileCopyrightText: 2026 Christian Semmelmann
# SPDX-License-Identifier: Apache-2.0

# Runs the test suite with code coverage and prints line coverage per module.
#
# Usage: coverage.sh [--self-test]
#
# Runs `swift test --enable-code-coverage`, then `llvm-cov export` (lcov, which keeps absolute paths) over every test bundle that
# carries coverage data, and prints one line per directory under Sources/ and a total:
#   module  lines  covered  percent
# Exit status is 0 whatever the numbers. A failing test run, a missing profdata file or a failing
# llvm-cov stops the script with a non-zero status before any report. A test bundle without
# coverage data is skipped with a note.
#
# --self-test aggregates scripts/fixtures/coverage-report.lcov and compares the table, and checks that
# a failing export stops the script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SWIFT=/usr/bin/swift
IGNORE_REGEX='\.build|/Tests/|checkouts'
WORK_DIR=""

cleanup() {
    [[ -z "${WORK_DIR}" ]] || rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

die() {
    printf 'coverage.sh: %s\n' "$*" >&2
    return 1
}

# modules ROOT: prints the directory names under ROOT/Sources, one per line.
modules() {
    local dir
    for dir in "$1"/Sources/*/; do
        [[ -d "${dir}" ]] || continue
        basename "${dir}"
    done
}

# aggregate MODULE...: reads an `llvm-cov export -format=lcov` on stdin and prints the table.
# Files outside Sources/<module>/ count toward no module.
aggregate() {
    awk -v modules="$*" '
        BEGIN {
            n = split(modules, names, " ")
            for (i = 1; i <= n; i++) {
                lines[names[i]] = 0
                hit[names[i]] = 0
            }
        }
        /^SF:/ {
            module = $0
            if (module !~ /\/Sources\/[^\/]+\//) {
                module = ""
            } else {
                sub(/^.*\/Sources\//, "", module)
                sub(/\/.*$/, "", module)
            }
        }
        /^LF:/ && (module in lines) { lines[module] += substr($0, 4) }
        /^LH:/ && (module in lines) { hit[module] += substr($0, 4) }
        function row(name, total, covered) {
            percent = "n/a"
            if (total > 0) percent = sprintf("%.1f%%", covered * 100 / total)
            printf "%-26s %7d %7d %7s\n", name, total, covered, percent
        }
        END {
            printf "%-26s %7s %7s %7s\n", "module", "lines", "covered", "percent"
            for (i = 1; i <= n; i++) {
                row(names[i], lines[names[i]], hit[names[i]])
                sumLines += lines[names[i]]
                sumHit += hit[names[i]]
            }
            row("total", sumLines, sumHit)
        }'
}

# export_lcov DEST COMMAND...: runs COMMAND with its output in DEST; a failing COMMAND stops the script
# before any table is printed.
export_lcov() {
    local dest="$1"
    shift
    "$@" >"${dest}" || die "llvm-cov export failed"
}

run() {
    local bin_path codecov profdata bundle name binary objects=() mods=() symbols
    local module
    while IFS= read -r module; do
        mods+=("${module}")
    done < <(modules "${REPO_ROOT}")

    cd "${REPO_ROOT}"
    "${SWIFT}" test --enable-code-coverage || die "swift test failed"
    codecov="$("${SWIFT}" test --show-codecov-path)"
    profdata="$(dirname "${codecov}")/default.profdata"
    [[ -f "${profdata}" ]] || die "profdata not found: ${profdata}"

    bin_path="$("${SWIFT}" build --show-bin-path)"
    for bundle in "${bin_path}"/*.xctest; do
        [[ -d "${bundle}" ]] || continue
        name="$(basename "${bundle}" .xctest)"
        binary="${bundle}/Contents/MacOS/${name}"
        symbols=""
        [[ ! -f "${binary}" ]] || symbols="$(otool -l "${binary}")"
        if [[ "${symbols}" != *__llvm_covmap* ]]; then
            printf 'note: %s has no coverage data, skipped\n' "${name}" >&2
            continue
        fi
        objects+=("${binary}")
    done
    [[ "${#objects[@]}" -gt 0 ]] || die "no test bundle with coverage data under ${bin_path}"

    local args=("${objects[0]}")
    local object
    for object in "${objects[@]:1}"; do
        args+=(-object "${object}")
    done
    WORK_DIR="$(mktemp -d)"
    export_lcov "${WORK_DIR}/report.lcov" xcrun llvm-cov export -format=lcov -instr-profile "${profdata}" \
        -ignore-filename-regex "${IGNORE_REGEX}" "${args[@]}"
    aggregate "${mods[@]}" <"${WORK_DIR}/report.lcov"
}

self_test() {
    local want got
    want="$(
        cat <<'TABLE'
module                       lines covered percent
ParbakeVersion                  10      10  100.0%
RuntimeMacOS                   300     180   60.0%
container-runtime-macos         40       0    0.0%
parbake                         50      40   80.0%
parbake-agent                    0       0     n/a
total                          400     230   57.5%
TABLE
    )"
    got="$(aggregate ParbakeVersion RuntimeMacOS container-runtime-macos parbake parbake-agent \
        <"${SCRIPT_DIR}/fixtures/coverage-report.lcov")"
    if [[ "${got}" != "${want}" ]]; then
        printf 'self-test FAILED: aggregation differs\n--- want\n%s\n--- got\n%s\n' "${want}" "${got}" >&2
        return 1
    fi
    WORK_DIR="$(mktemp -d)"
    if (export_lcov "${WORK_DIR}/report.lcov" false) 2>/dev/null; then
        printf 'self-test FAILED: a failing export did not stop the script\n' >&2
        return 1
    fi
    printf 'self-test ok: fixture aggregates per module, a failing export stops\n'
}

main() {
    case "${1:-}" in
        --self-test)
            self_test
            ;;
        -h | --help)
            sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
            ;;
        "")
            run
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
}

main "$@"
