#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Build the pinned MKXP source locally. An existing trusted dependency
# tree can supply SDL, Ruby and ANGLE via --engine-tree /path/to/engine.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/cores/mkxp/.version"
DEST="$ROOT/ios/Dependencies/mkxp-core"
if [ -z "${MKXP_CORE_LOCKED:-}" ]; then
    MKXP_CORE_LOCKED=1 exec lockf -k "$DEST.lock" "$0" "$@"
fi
WORK="$(mktemp -d /tmp/empo-mkxp.XXXXXX)"
STAGE="$(mktemp -d "$DEST.XXXXXX")"
trap 'rm -rf "$WORK" "$STAGE"' EXIT
sdks=(iphoneos iphonesimulator macosx)

checkout() {
    git init -q "$1"
    git -C "$1" fetch -q --depth 1 "https://github.com/$MKXP_CORE_REPO.git" "$MKXP_CORE_COMMIT"
    git -C "$1" checkout -q --detach FETCH_HEAD
    git -C "$1" -c url.https://github.com/.insteadOf=git@github.com: submodule update --init --depth 1 hmode7
}

if [[ $# == 0 ]]; then
    engine="$WORK/package"
    checkout "$engine"
    export PATH="$(brew --prefix bison)/bin:$PATH"
    for sdk in "${sdks[@]}"; do
        # The dependency recipes patch shared source files for one SDK.
        tree="$WORK/$sdk"
        checkout "$tree"
        git -C "$tree" -c url.https://github.com/.insteadOf=git@github.com: submodule update --init --depth 1 deps/sources
        "$tree/tools/build-deps-ios.sh" "$sdk"
        "$tree/tools/build-engine-ios.sh" --sdk "$sdk"
        mv "$tree/deps/build-$sdk-arm64" "$engine/deps/"
        rm -rf "$tree"
    done
elif [[ $# == 2 && "$1" == --engine-tree ]]; then
    engine="$(cd "$2" && pwd)"
    if [[ "$(git -C "$engine" rev-parse HEAD)" != "$MKXP_CORE_COMMIT" ||
          "$(git -C "$engine" status --porcelain --untracked-files=normal)" != "" ||
          "$(git -C "$engine" submodule status hmode7)" != " "* ]]; then
        echo "error: --engine-tree requires a clean checkout of $MKXP_CORE_COMMIT with hmode7 initialized" >&2
        exit 1
    fi
    core="$("$engine/tools/core-fingerprint.sh")"
    binding="$("$engine/tools/binding-fingerprint.sh")"
    for sdk in "${sdks[@]}"; do
        lib="$engine/deps/build-$sdk-arm64/lib"
        if [[ "$(cat "$lib/.mkxp-core-fingerprint" 2>/dev/null)" != "$core" ||
              "$(cat "$lib/.mkxp-binding-fingerprint" 2>/dev/null)" != "$binding" ]]; then
            "$engine/tools/build-engine-ios.sh" --sdk "$sdk" --obj "$WORK/obj-$sdk"
            rm -rf "$WORK/obj-$sdk"
        fi
    done
else
    echo "usage: cores/mkxp/rebuild-local.sh [--engine-tree /path/to/pinned/engine]" >&2
    exit 2
fi

"$engine/tools/package-ios.sh" --tag "$MKXP_CORE_VERSION" --out "$STAGE/engine.tar.gz"
digest="$(shasum -a 256 "$STAGE/engine.tar.gz" | awk '{print $1}')"
printf '%s %s\n' "$MKXP_CORE_COMMIT" "$digest" > "$STAGE/receipt"
mv -f "$STAGE/engine.tar.gz" "$DEST.tar.gz"
mv -f "$STAGE/receipt" "$DEST.receipt"
"$ROOT/cores/mkxp/fetch.sh"
