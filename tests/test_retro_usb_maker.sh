#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${ROOT}/overlay/usr/local/sbin/retro-usb-maker"
[[ -x "$TOOL" || -f "$TOOL" ]]
bash -n "$TOOL"
help="$(bash "$TOOL" --help)"
grep -q -- '--iso FILE.iso --device /dev/sdX' <<< "$help"
grep -q 'persistence.conf' <<< "$help"
if bash "$TOOL" --definitely-invalid >/dev/null 2>&1; then
    echo "unknown arguments must be rejected" >&2
    exit 1
fi
echo "retro-usb-maker interface tests passed"
