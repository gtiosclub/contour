#!/bin/bash
#
# check-dependencies.sh — enforce the isolation rule.
#
# Four teams work in parallel. That only holds if no team's package can depend
# on another team's package. This script is the mechanical check; CI runs it on
# every PR.
#
# THE RULE
#   ContourCore            depends on nothing
#   SurfaceUnderstanding   depends on ContourCore only
#   Tracking               depends on ContourCore only
#   ContourFeedback        depends on ContourCore only
#   ContourUI              depends on ContourCore only
#   ContourMocks           depends on ContourCore only
#
# ContourApp and Harness may depend on everything — they are the wiring, and
# they are Xcode targets, not packages, so they are not checked here.
#
# If this fails on your PR, the fix is almost never "add the dependency". It is
# usually one of:
#   - the type you need belongs in ContourCore (that is a four-lead change), or
#   - the wiring belongs in ContourApp, not in your package.

set -euo pipefail

cd "$(dirname "$0")/.."

status=0

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

    # Remote dependencies are not banned outright, but they are a four-lead
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

echo "Checking package isolation…"
check ContourCore
check SurfaceUnderstanding ContourCore
check Tracking             ContourCore
check ContourFeedback      ContourCore
check ContourUI            ContourCore
check ContourMocks         ContourCore

# A team package must not import another team's module either — a manifest can
# be clean while a source file reaches across via the app's link graph.
echo
echo "Checking imports…"
teams=(SurfaceUnderstanding Tracking ContourFeedback ContourUI ContourMocks)
imports_clean=1
for package in "${teams[@]}"; do
    for other in "${teams[@]}"; do
        [[ "$package" == "$other" ]] && continue
        if grep -rqE "^ *import +$other\b" "Packages/$package/Sources" 2>/dev/null; then
            echo "FAIL  $package imports $other"
            status=1
            imports_clean=0
        fi
    done
done
[[ $imports_clean -eq 1 ]] && echo "ok    no cross-team imports"

echo
if [[ $status -eq 0 ]]; then
    echo "Package isolation holds."
else
    echo "Package isolation violated — see above."
fi
exit $status
