#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${ROOT}/overlay/usr/local/sbin/retro-hardware-report"
[[ -f "$TOOL" ]]
bash -n "$TOOL"
help="$(bash "$TOOL" --help)"
grep -q -- '--arm-persistence' <<< "$help"
grep -q -- '--check-persistence' <<< "$help"
if bash "$TOOL" --invalid-option >/dev/null 2>&1; then
    echo "unknown options must be rejected" >&2
    exit 1
fi
if bash "$TOOL" --arm-persistence --check-persistence >/dev/null 2>&1; then
    echo "multiple options must be rejected" >&2
    exit 1
fi
echo "retro-hardware-report interface tests passed"
