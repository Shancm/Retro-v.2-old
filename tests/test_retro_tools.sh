#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${ROOT}/scripts/03_modules_setup.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
HELPER="${WORK}/retro-fetch-tools"
python3 - "$SOURCE" "$HELPER" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = 'retro_write "${RETRO_HELPER_DIR}/retro-fetch-tools" 0755 <<\'EOF\'\n'
start = source.find(marker)
if start < 0:
    raise SystemExit("retro-fetch-tools heredoc was not found")
start = source.find("\n", start) + 1
end = source.find("\nEOF\n}", start)
if end < 0:
    raise SystemExit("retro-fetch-tools heredoc terminator was not found")
Path(sys.argv[2]).write_text(source[start:end] + "\n", encoding="utf-8")
PY
bash -n "$HELPER"
shellcheck -x "$HELPER"
help="$(bash "$HELPER" --help)"
grep -q 'rustscan httpx naabu' <<< "$help"
RETRO_TOOLS_MANIFEST="${WORK}/manifest" bash "$HELPER" --list | grep -q 'no tools staged yet'
source "$HELPER"

printf 'pinned asset test\n' > "${WORK}/asset.bin"
digest="$(sha256sum "${WORK}/asset.bin" | awk '{print $1}')"
verify_pinned_sha256 "${WORK}/asset.bin" "$digest"
if verify_pinned_sha256 "${WORK}/asset.bin" "0000000000000000000000000000000000000000000000000000000000000000"; then
    echo "wrong pinned digest was accepted" >&2
    exit 1
fi
if verify_pinned_sha256 "${WORK}/asset.bin" "not-a-sha256"; then
    echo "malformed pinned digest was accepted" >&2
    exit 1
fi

cat > "${WORK}/release.json" <<'JSON'
{"tag_name":"v1.2.3","assets":[{"name":"retro-test.zip","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","browser_download_url":"https://example.invalid/retro-test.zip"}]}
JSON
asset_info="$(release_asset_info "${WORK}/release.json" "v1.2.3" "retro-test.zip")"
grep -q 'https://example.invalid/retro-test.zip' <<< "$asset_info"
grep -q 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' <<< "$asset_info"
if release_asset_info "${WORK}/release.json" "v9.9.9" "retro-test.zip" >/dev/null 2>&1; then
    echo "release tag mismatch was accepted" >&2
    exit 1
fi
echo "retro-fetch-tools verification tests passed"
