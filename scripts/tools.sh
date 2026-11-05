#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Overlabing
#
# Copy this file into your repository (as scripts/tools.sh, say) next to a pin file, and your check scripts source
# AppTooling from a tagged release, checked against a checksum:
#
#   scripts/apptooling.pin       version=0.1.0
#                                sha256=<sha-256 of AppTooling-0.1.0.tar.gz, from the release notes>
#
#   tools=$(scripts/tools.sh) || exit 1          # downloads once, prints the AppTooling directory
#   . "$tools/lib/gate.sh"
#   scripts/tools.sh install-hooks [--no-leak-scan]
#
# The release is public: no token, no secret, works in CI. A download that does not match the pinned checksum is thrown
# away. Everything lands in <repository>/.build/tools/ (git-ignored), one folder per version.
#
# APPTOOLING_ARCHIVE=<file>   use this archive instead of downloading it (the checksum still has to match)
# APPTOOLING_PIN=<file>       the pin file (default: apptooling.pin next to this script)
set -u
here=$(cd "$(dirname "$0")" && pwd)
repository=$(cd "$here/.." && pwd)
pin=${APPTOOLING_PIN:-$here/apptooling.pin}

field() { sed -n "s/^$1=//p" "$pin" | head -n 1; }
[ -r "$pin" ] || { echo "FAILED: no pin file $pin (version=… and sha256=…)" >&2; exit 1; }
version=$(field version)
sha256=$(field sha256)
[ -n "$version" ] && [ -n "$sha256" ] || { echo "FAILED: $pin needs version= and sha256=" >&2; exit 1; }

destination=$repository/.build/tools/AppTooling-$version
if [ ! -f "$destination/VERSION" ]; then
    work=$(mktemp -d "${TMPDIR:-/tmp}/apptooling.XXXXXX") || exit 1
    trap 'rm -rf "${work:?}"' EXIT
    archive=$work/AppTooling-$version.tar.gz
    if [ -n "${APPTOOLING_ARCHIVE:-}" ]; then
        cp "$APPTOOLING_ARCHIVE" "$archive" || exit 1
    else
        curl --fail --silent --show-error --location --retry 3 \
            "https://github.com/Overlabing/AppTooling/releases/download/v$version/AppTooling-$version.tar.gz" \
            -o "$archive" || { echo "FAILED: cannot download AppTooling $version" >&2; exit 1; }
    fi
    actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
    [ "$actual" = "$sha256" ] || { echo "FAILED: AppTooling $version has checksum $actual, the pin says $sha256" >&2; exit 1; }
    mkdir "$work/tree" && tar -xzf "$archive" -C "$work/tree" --strip-components=1 || exit 1
    [ "$(cat "$work/tree/VERSION")" = "$version" ] || { echo "FAILED: the archive is not AppTooling $version" >&2; exit 1; }
    mkdir -p "$repository/.build/tools"
    rm -rf "${destination:?}"
    mv "$work/tree" "$destination"
    echo "OK: AppTooling $version fetched into $destination" >&2
fi

case ${1:-} in
    "") echo "$destination" ;;
    install-hooks) shift; (cd "$repository" && "$destination/bin/install-hooks" "$@") ;;
    *) echo "usage: tools.sh [install-hooks [--no-leak-scan]]" >&2; exit 2 ;;
esac
