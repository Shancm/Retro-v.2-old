#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${ROOT}/overlay/usr/local/bin/retro"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

say() { :; }
ok() { :; }
warn() { :; }
die() { printf 'unexpected die: %s\\n' "$*" >&2; return 1; }

# Load only the update function so tests never dispatch the production CLI.
eval "$(sed -n '/^update_scripts() {/,/^cmd_update() {/p' "${CLI}" | sed '$d')"

PASS=0
FAIL=0
report() {
    local name="$1" status="$2"
    if [[ "${status}" == pass ]]; then
        PASS=$((PASS + 1))
        printf 'PASS %s\\n' "${name}"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s\\n' "${name}" >&2
    fi
}

make_case() {
    CASE_DIR="$(mktemp -d "${TMP}/case.XXXXXX")"
    ARCHIVE="${CASE_DIR}/update.tar.gz"
    DEST="${CASE_DIR}/root"
    mkdir -p "${DEST}"
}

make_archive() {
    local kind="$1"
    python3 - "${ARCHIVE}" "${kind}" <<'PY'
import io
import sys
import tarfile

archive, kind = sys.argv[1:]
with tarfile.open(archive, "w:gz") as tf:
    def add_file(name, body):
        data = body.encode()
        item = tarfile.TarInfo(name)
        item.size = len(data)
        item.mode = 0o755
        tf.addfile(item, io.BytesIO(data))

    if kind == "valid":
        add_file("usr/local/bin/retro", "#!/usr/bin/env bash\\necho updated\\n")
        add_file("opt/retro-ai/retro_ai.py", "print('updated')\\n")
    elif kind == "absolute":
        add_file("/usr/local/bin/retro", "#!/bin/bash\\n")
    elif kind == "traversal":
        add_file("opt/retro-os/../../tmp/evil", "bad")
    elif kind == "symlink":
        item = tarfile.TarInfo("opt/retro-os/link")
        item.type = tarfile.SYMTYPE
        item.linkname = "/etc/passwd"
        tf.addfile(item)
    elif kind == "hardlink":
        add_file("opt/retro-os/source", "safe")
        item = tarfile.TarInfo("opt/retro-os/hard")
        item.type = tarfile.LNKTYPE
        item.linkname = "opt/retro-os/source"
        tf.addfile(item)
    elif kind == "device":
        item = tarfile.TarInfo("opt/retro-os/device")
        item.type = tarfile.CHRTYPE
        item.devmajor = 1
        item.devminor = 3
        tf.addfile(item)
    elif kind == "outside":
        add_file("etc/passwd", "bad")
    elif kind == "bad-bash":
        add_file("usr/local/bin/retro", "#!/bin/bash\\nif then\\n")
    elif kind == "bad-python":
        add_file("opt/retro-ai/retro_ai.py", "def broken(:\\n")
    else:
        raise SystemExit("unknown archive kind")
PY
}

checksum() {
    sha256sum "${ARCHIVE}" > "${ARCHIVE}.sha256"
}

run_update() {
    RETRO_UPDATE_URL="file://${ARCHIVE}"
    RETRO_UPDATE_ALLOW_FILE=1
    RETRO_UPDATE_DEST_ROOT="${DEST}"
    RETRO_UPDATE_REPO=""
    update_scripts >/dev/null 2>&1
}

expect_reject() {
    local name="$1" kind="$2"
    make_case
    make_archive "${kind}"
    checksum
    if run_update; then report "${name}" fail; else report "${name}" pass; fi
}

# 1: a valid authenticated test archive installs the CLI.
make_case
make_archive valid
checksum
if run_update && [[ -x "${DEST}/usr/local/bin/retro" ]] && grep -q 'echo updated' "${DEST}/usr/local/bin/retro"; then
    report "valid archive installs atomically" pass
else
    report "valid archive installs atomically" fail
fi

# 2: missing checksum is rejected.
make_case
make_archive valid
if run_update; then report "missing checksum rejected" fail; else report "missing checksum rejected" pass; fi

# 3: a mismatched checksum is rejected.
make_case
make_archive valid
printf '%064d  update.tar.gz\\n' 0 > "${ARCHIVE}.sha256"
if run_update; then report "checksum mismatch rejected" fail; else report "checksum mismatch rejected" pass; fi

# 4: a corrupt gzip stream is rejected even with a matching digest.
make_case
printf 'not a gzip archive' > "${ARCHIVE}"
checksum
if run_update; then report "invalid gzip rejected" fail; else report "invalid gzip rejected" pass; fi

# 5-12: archive path, type and source syntax validation.
expect_reject "absolute archive path rejected" absolute
expect_reject "parent traversal rejected" traversal
expect_reject "symbolic link rejected" symlink
expect_reject "hard link rejected" hardlink
expect_reject "device node rejected" device
expect_reject "path outside allow-list rejected" outside
expect_reject "invalid Bash source rejected" bad-bash
expect_reject "invalid Python source rejected" bad-python

printf '\nRetro update tests: %d passed, %d failed\\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
