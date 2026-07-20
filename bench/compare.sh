#!/usr/bin/env bash
# bench/compare.sh — measure cook vs turbo rebuild behavior on this repo.
#
# Reproduces the numbers quoted in README.md. Requires a working setup
# (pnpm install, cook modules install, the dummy .env; see README "Build it").
#
# What it measures, each from a settled steady state:
#   1. warm no-op          nothing changed; both tools should do nothing
#   2. comment-only edit   comment appended to packages/env/index.ts; the
#                          package rebuilds to byte-identical output
#   3. real API change     export appended to packages/env/index.ts; the
#                          package's output genuinely changes
#   4. outputs deleted     every declared build output removed, then rebuilt
#
# `next build` rewrites apps/web/app/.well-known/workflow/v1/manifest.json,
# a generated file inside the web app's SOURCE tree; the Cookfile excludes
# it from task inputs (cook_pnpm 0.5.0 exclude_inputs), so foreign next
# builds no longer re-key cook's web task. Since cook 0.6.4, reverting an
# edit restores from the store instead of re-executing, so
# settles are cheap; every scenario still settles both tools first as a
# guard against environment-sensitive Turbo hashes (globalEnv "*").
# Expect the whole run to take about five minutes.
#
# Only packages/env is edited, and only if it is clean in git; edits are
# reverted on exit.

set -euo pipefail
cd "$(dirname "$0")/.."

COOK_CMD=(cook build)
TURBO_CMD=(pnpm exec dotenv -e .env -- turbo run build --filter='!@cap/sdk-recorder')
OUTPUTS=(
    packages/env/dist packages/utils/dist packages/sdk-embed/dist
    packages/web-domain/dist packages/database/dist packages/web-backend/dist
    apps/chrome-extension/dist apps/web/.next apps/desktop/.output
)

for tool in cook pnpm git; do
    command -v "$tool" >/dev/null || { echo "error: $tool not found" >&2; exit 1; }
done
[[ -f .env ]] || { echo "error: no .env; see README 'Build it'" >&2; exit 1; }
git diff --quiet -- packages/env ||
    { echo "error: packages/env has uncommitted changes; refusing to edit it" >&2; exit 1; }

trap 'git checkout -q -- packages/env' EXIT

now() { echo "${EPOCHREALTIME/./}"; }   # microseconds

# Each run_* sets: SECS (wall clock), RERAN (tasks that actually executed),
# TOTAL (tasks considered).
run_cook() {
    local t0 t1 out
    t0=$(now); out=$("${COOK_CMD[@]}" 2>&1); t1=$(now)
    SECS=$(awk -v us=$((t1 - t0)) 'BEGIN { printf "%.1f", us / 1e6 }')
    RERAN=$(grep -oE '\([0-9]+/[0-9]+ cached\)' <<<"$out" |
        awk -F'[(/ ]' '$2 < $3 { n++ } END { print n + 0 }')
    TOTAL=$(grep -cE '\([0-9]+/[0-9]+ cached\)' <<<"$out")
}

run_turbo() {
    local t0 t1 out cached
    t0=$(now); out=$("${TURBO_CMD[@]}" 2>&1 | tr -d '\0'); t1=$(now)
    SECS=$(awk -v us=$((t1 - t0)) 'BEGIN { printf "%.1f", us / 1e6 }')
    TOTAL=$(grep -oE 'Tasks: +[0-9]+ successful, +([0-9]+) total' <<<"$out" |
        grep -oE '[0-9]+ total' | grep -oE '[0-9]+')
    cached=$(grep -oE 'Cached: +[0-9]+' <<<"$out" | grep -oE '[0-9]+')
    RERAN=$((TOTAL - cached))
}

# Run both tools until neither re-runs anything, so every scenario starts
# from the same steady state.
settle() {
    local i
    for i in 1 2 3 4 5; do
        run_cook;  local c=$RERAN
        run_turbo; local t=$RERAN
        (( c == 0 && t == 0 )) && return 0
        echo "  settling ($i): cook re-ran $c, turbo re-ran $t" >&2
    done
    echo "error: caches did not settle after 5 rounds" >&2
    exit 1
}

declare -A R  # results: R[scenario,tool] = "reran/total in secs"
record() { R["$1,$2"]="$RERAN of $TOTAL tasks, ${SECS}s"; }

echo "== settling both caches (may build from cold; be patient)" >&2
settle

echo "== scenario: warm no-op" >&2
run_cook;  record noop cook
run_turbo; record noop turbo

# The appended lines carry a timestamp: an edit either tool has seen before
# is a plain cache hit (that is the whole point of cook), which would turn a
# repeat benchmark run into a measurement of nothing.
NONCE=$(date +%s)

scenario_edit() {  # $1 = key, $2 = line to append
    echo "== scenario: append '$2' to packages/env/index.ts" >&2
    echo "$2" >>packages/env/index.ts
    run_cook;  record "$1" cook
    run_turbo; record "$1" turbo
    git checkout -q -- packages/env/index.ts
    settle
}
scenario_edit comment "// bench: comment-only edit $NONCE"
scenario_edit real    "export const COOK_BENCH_CANARY_$NONCE = 1;"

echo "== scenario: all declared outputs deleted" >&2
rm -rf "${OUTPUTS[@]}"
run_cook; record deleted cook
settle
rm -rf "${OUTPUTS[@]}"
run_turbo; record deleted turbo
settle

echo
echo "$(cook --version 2>/dev/null | head -1), turbo $(pnpm exec turbo --version 2>/dev/null), $(nproc) cores"
echo
printf '| %-45s | %-25s | %-25s |\n' "Scenario" "cook" "turbo"
printf '| %s | %s | %s |\n' "$(printf '%.0s-' {1..45})" "$(printf '%.0s-' {1..25})" "$(printf '%.0s-' {1..25})"
printf '| %-45s | %-25s | %-25s |\n' \
    "Warm no-op"                                  "${R[noop,cook]}"    "${R[noop,turbo]}"
printf '| %-45s | %-25s | %-25s |\n' \
    "Comment-only edit in @cap/env"               "${R[comment,cook]}" "${R[comment,turbo]}"
printf '| %-45s | %-25s | %-25s |\n' \
    "Real API change in @cap/env"                 "${R[real,cook]}"    "${R[real,turbo]}"
printf '| %-45s | %-25s | %-25s |\n' \
    "Delete all build outputs, rebuild"           "${R[deleted,cook]}" "${R[deleted,turbo]}"
