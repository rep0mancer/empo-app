#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/cores/mkxp/.version"
DEST="$ROOT/ios/Dependencies/mkxp-core"
if [ -z "${MKXP_CORE_LOCKED:-}" ]; then
    MKXP_CORE_LOCKED=1 exec lockf -k "$DEST.lock" "$0" "$@"
fi

read -r commit digest < "$DEST.receipt" 2>/dev/null || true
if [[ "${commit:-}" != "$MKXP_CORE_COMMIT" || ! "${digest:-}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: build the pinned personal engine first: cores/mkxp/rebuild-local.sh" >&2
    exit 1
fi
stamp="$MKXP_CORE_VERSION $commit $digest"
if [[ "$(cat "$DEST/.fetched-pin" 2>/dev/null)" == "$stamp" &&
      "$(sed -n 's/^commit=//p' "$DEST/MANIFEST" 2>/dev/null)" == "$commit" ]]; then
    exit 0
fi

WORK="$(mktemp -d "$DEST.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
echo "$digest  $DEST.tar.gz" | shasum -a 256 -c >/dev/null
tar -xzf "$DEST.tar.gz" -C "$WORK"
if [[ "$(sed -n 's/^commit=//p' "$WORK/MANIFEST")" != "$commit" ]]; then
    echo "error: local MKXP archive has a different source revision. Run cores/mkxp/rebuild-local.sh" >&2
    exit 1
fi
printf '%s\n' "$stamp" > "$WORK/.fetched-pin"
rm -rf "$DEST"
mv "$WORK" "$DEST"
