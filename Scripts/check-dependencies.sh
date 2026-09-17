#!/bin/bash
#
# check-dependencies.sh — enforce the isolation rule.
#
# Three teams work in parallel. That only holds if no team's package can depend
# on another team's package. This script is the mechanical check; CI runs it on
# every PR.
#
# THE RULE
#   ContourCore            depends on nothing
#   SurfaceUnderstanding   source: ContourCore only   tests: + ContourMocks
#   Tracking               source: ContourCore only   tests: + ContourMocks
#   ContourFeedback        source: ContourCore only   tests: + ContourMocks
#   ContourUI              source: ContourCore only   tests: + ContourMocks
#   ContourMocks           depends on ContourCore only
#
# The test-target carve-out is deliberate: every team builds against the shared
# deterministic fakes long before another team has working code, and a fake you
# cannot import from a test is useless. Shipping code still cannot see it —
# `import ContourMocks` under Sources/ is an error, and that is what stops the
# fakes reaching a user's phone.
#
# ContourCore is the one exception to the carve-out: ContourMocks depends on
# ContourCore, so ContourCore's own tests cannot depend on ContourMocks without
# creating a cycle.
#
# ContourApp and Harness may depend on everything — they are the wiring, and
# they are Xcode targets, not packages, so they are not checked here.
#
# If this fails on your PR, the fix is almost never "add the dependency". It is
# usually one of:
#   - the type you need belongs in ContourCore (that is a three-lead change), or
#   - the wiring belongs in ContourApp, not in your package.

set -euo pipefail

cd "$(dirname "$0")/.."

status=0

# Manifest-level check: which packages may appear as `.package(path:)` at all.
check() {
    local package="$1"
    shift
    local allowed=("$@")
    local manifest="Packages/$package/Package.swift"
    local failed=0

    if [[ ! -f "$manifest" ]]; then
        echo "FAIL  $package — no Package.swift at $manifest"
        status=1
        return
    fi

    # Every local path dependency declared in the manifest, as a bare name.
    local found
    found=$(grep -oE '\.package\(path: *"[^"]+"' "$manifest" \
            | sed -E 's|.*/||; s|"$||' || true)

    local dependency
    for dependency in $found; do
        local ok=0
        local candidate
        for candidate in "${allowed[@]+"${allowed[@]}"}"; do
            [[ "$dependency" == "$candidate" ]] && ok=1
        done
        if [[ $ok -eq 0 ]]; then
            echo "FAIL  $package must not depend on $dependency"
            status=1
            failed=1
        fi
    done

    # Remote dependencies are not banned outright, but they are a three-lead
    # decision in ContourCore and a lead's decision anywhere else. Flag them.
    if grep -qE '\.package\(url:' "$manifest"; then
        if [[ "$package" == "ContourCore" ]]; then
            echo "FAIL  ContourCore must depend on nothing, including remote packages"
            status=1
            failed=1
        else
            echo "WARN  $package declares a remote dependency — is that agreed?"
        fi
    fi

    if [[ $failed -eq 0 ]]; then
        echo "ok    $package"
    fi
}

echo "Checking package manifests…"
check ContourCore
check SurfaceUnderstanding ContourCore ContourMocks
check Tracking             ContourCore ContourMocks
check ContourFeedback      ContourCore ContourMocks
check ContourUI            ContourCore ContourMocks
check ContourMocks         ContourCore

# The manifest check above lets ContourMocks in the door; this makes sure it only
# ever reaches the test target. A `.target` whose dependency list names
# ContourMocks would pass the manifest check and still ship fakes in the app.
echo
echo "Checking that ContourMocks stays out of shipping targets…"
mocks_scoped=1
for package in SurfaceUnderstanding Tracking ContourFeedback ContourUI; do
    manifest="Packages/$package/Package.swift"

    # The source target's dependency list: from `.target(` up to the first
    # `.testTarget(`. If ContourMocks is named in there, it ships.
    if sed -n '/\.target(/,/\.testTarget(/p' "$manifest" | grep -q 'ContourMocks'; then
        echo "FAIL  $package names ContourMocks in its source target"
        status=1
        mocks_scoped=0
    fi
done
[[ $mocks_scoped -eq 1 ]] && echo "ok    ContourMocks is test-only in every team package"

# A team package must not import another team's module either — a manifest can
# be clean while a source file reaches across via the app's link graph.
#
# Sources/ may import neither another team's module nor ContourMocks.
# Tests/ may import ContourMocks, but still not another team's module.
echo
echo "Checking imports…"
teams=(SurfaceUnderstanding Tracking ContourFeedback ContourUI ContourMocks)
imports_clean=1
for package in "${teams[@]}"; do
    for other in "${teams[@]}"; do
        [[ "$package" == "$other" ]] && continue

        # Sources: no cross-team import, and no ContourMocks.
        if grep -rqE "^ *(@testable )?import +$other\b" "Packages/$package/Sources" 2>/dev/null; then
            echo "FAIL  $package imports $other in Sources/"
            status=1
            imports_clean=0
        fi

        # Tests: no cross-team import, but ContourMocks is allowed.
        [[ "$other" == "ContourMocks" ]] && continue
        if grep -rqE "^ *(@testable )?import +$other\b" "Packages/$package/Tests" 2>/dev/null; then
            echo "FAIL  $package imports $other in Tests/"
            status=1
            imports_clean=0
        fi
    done
done
[[ $imports_clean -eq 1 ]] && echo "ok    no cross-team imports"

# ContourCore genuinely depends on nothing, in sources and tests alike.
echo
echo "Checking that ContourCore stays self-contained…"
if grep -rqE "^ *(@testable )?import +(SurfaceUnderstanding|Tracking|ContourFeedback|ContourUI|ContourMocks)\b" \
        Packages/ContourCore 2>/dev/null; then
    echo "FAIL  ContourCore imports a package — it must depend on nothing"
    status=1
else
    echo "ok    ContourCore"
fi

echo
if [[ $status -eq 0 ]]; then
    echo "Package isolation holds."
else
    echo "Package isolation violated — see above."
fi
exit $status
