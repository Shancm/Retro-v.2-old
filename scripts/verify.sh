#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
errors=0
required=(
  config/retro.conf
  stages/01-engine/setup.sh
  stages/02-desktop/setup.sh
  stages/03-security/setup.sh
  stages/04-installer/setup.sh
  rootfs/opt/retro-ai/bujji.py
  rootfs/usr/local/bin/retro
  scripts/verify.sh
  scripts/build.sh
  .github/workflows/build-iso.yml
)
for rel in "${required[@]}"; do
  if [[ ! -f "$ROOT/$rel" ]]; then echo "ERROR missing: $rel"; errors=$((errors+1)); fi
done
while IFS= read -r -d '' f; do
  if ! bash -n "$f"; then echo "ERROR bash syntax: $f"; errors=$((errors+1)); fi
done < <(find "$ROOT" -type f -name '*.sh' -print0)
if command -v python3 >/dev/null; then
  python3 -m py_compile "$ROOT/rootfs/opt/retro-ai/bujji.py" || errors=$((errors+1))
fi
if grep -RInE 'TODO|PLACEHOLDER|DUMMY_CODE' "$ROOT" --exclude=verify.sh; then
  echo "WARNING: placeholder marker found; review output above."
fi
if ((errors)); then echo "Verification failed: $errors error(s)." >&2; exit 1; fi
echo "Static verification passed. This does not prove ISO bootability or hardware compatibility."
