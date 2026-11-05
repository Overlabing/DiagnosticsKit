#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Overlabing
#
# The gate before every commit and in CI: the tests with French then English pinned, the build for iOS, and the leak
# scan of this repository, tree and whole history. Prints OK:/FAILED: lines and stops at the first failure.
#
# CI cannot read the private terms file, so it scans with AppTooling's public patterns only. On a Mac that has the file
# (OVERLABING_PRIVATE_TERMS, default ~/.config/overlabing/private-terms) the private terms are scanned as well.
set -u
cd "$(dirname "$0")"
tools=$(scripts/tools.sh) || exit 1
. "$tools/lib/gate.sh"

step "tests, French pinned" env OVERLABING_TEST_LANGUAGE=fr swift test
step "tests, English pinned" env OVERLABING_TEST_LANGUAGE=en swift test
step "build for the iOS simulator" xcodebuild -scheme DiagnosticsKit -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath .build/ios -quiet build
step "leak scan, public patterns, tree" "$tools/bin/leak-scan" --public tree
step "leak scan, public patterns, history" "$tools/bin/leak-scan" --public history

terms=${OVERLABING_PRIVATE_TERMS:-$HOME/.config/overlabing/private-terms}
if [ -r "$terms" ]; then
    step "leak scan, private terms, tree" "$tools/bin/leak-scan" tree
    step "leak scan, private terms, history" "$tools/bin/leak-scan" history
else
    echo "NOTE: no private terms file here (CI, or a Mac without it): the private terms were not scanned"
fi
gate_clean_log
echo "OK: all checks passed"
