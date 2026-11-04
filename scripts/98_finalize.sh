#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 - 98_finalize.sh   (runs as root INSIDE the build chroot)
#
# Runs AFTER the overlay's post-pass and BEFORE 99_selftest.sh:
#   * push /etc/skel into /home/retro (the user was created before the skeleton
#     existed) and fix ownership
#   * live-desktop installer launcher
#   * final initramfs, apt/dpkg audit, cache + log cleanup, machine-id reset
# =============================================================================
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/config.env"
retro_enable_traps "98_finalize.sh"
retro_require_chroot

export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C

HOME_DIR="/home/${RETRO_USER}"

ensure_retro_wallpaper() {
    local wallpaper="/usr/share/backgrounds/retro-wallpaper.png"
    retro_info "Ensuring the live desktop wallpaper exists before self-test"
    mkdir -p "$(dirname "${wallpaper}")"

    # Re-create the asset in the final chroot if an earlier stage or overlay
    # did not leave it in place. Keep this finalizer authoritative.
    if ! python3 - "${wallpaper}" <<'PY'
import os
import struct
import sys
import zlib

path = sys.argv[1]
width, height = 1280, 800
stops = [(0.00, (35, 145, 220)), (0.34, (20, 190, 175)),
         (0.67, (125, 92, 205)), (1.00, (245, 145, 72))]

def png_chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)

def pixel_at(x, y):
    t = x / (width - 1)
    for index in range(len(stops) - 1):
        p0, c0 = stops[index]
        p1, c1 = stops[index + 1]
        if t <= p1:
            ratio = (t - p0) / (p1 - p0)
            break
    else:
        ratio, c0, c1 = 1.0, stops[-2][1], stops[-1][1]
    lift = int(18 * (1.0 - y / (height - 1)))
    return bytes(max(1, min(255, int(c0[i] + (c1[i] - c0[i]) * ratio) + lift)) for i in range(3))

raw = bytearray()
for y in range(height):
    raw.append(0)
    for x in range(width):
        raw.extend(pixel_at(x, y))

png = (b"\x89PNG\r\n\x1a\n"
       + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
       + png_chunk(b"IDAT", zlib.compress(bytes(raw), 7))
       + png_chunk(b"IEND", b""))
with open(path, "wb") as output:
    output.write(png)
os.chmod(path, 0o644)
PY
    then
        retro_die "could not generate Retro OS wallpaper at ${wallpaper}"
    fi

    python3 - "${wallpaper}" <<'PY'
import struct
import sys

with open(sys.argv[1], "rb") as image:
    if image.read(8) != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("invalid PNG signature")
    ihdr_len, ihdr_type = struct.unpack(">I4s", image.read(8))
    if ihdr_len != 13 or ihdr_type != b"IHDR":
        raise SystemExit("missing or invalid IHDR chunk")
    dimensions = image.read(8)
    if len(dimensions) != 8:
        raise SystemExit("truncated PNG IHDR dimensions")
    width, height = struct.unpack(">II", dimensions)

if width < 1280 or height < 800:
    raise SystemExit(f"wallpaper resolution is below 1280x800 ({width}x{height})")
PY
    retro_ok "final wallpaper verified: ${wallpaper} (1280x800)"
}

sync_home_from_skel() {
    retro_info "Syncing /etc/skel into ${HOME_DIR}"
    [[ -d "${HOME_DIR}" ]] || retro_die "${HOME_DIR} does not exist - 01_engine_setup.sh did not create the user"
    cp -a /etc/skel/. "${HOME_DIR}/"

    if command -v calamares >/dev/null 2>&1; then
        mkdir -p "${HOME_DIR}/Desktop"
        retro_write "${HOME_DIR}/Desktop/install-retro-os.desktop" 0755 <<EOF
[Desktop Entry]
Type=Application
Name=Install ${RETRO_OS_NAME}
Comment=Install ${RETRO_OS_NAME} to this computer
Exec=pkexec calamares
Icon=system-software-install
Terminal=false
Categories=System;
EOF
    fi

    # Menus for the live user are the generated skeleton menus; make sure they
    # reflect the final tool set.
    "${RETRO_HELPER_DIR}/retro-menu-gen" --user "${HOME_DIR}"

    chown -R "${RETRO_USER}:${RETRO_USER}" "${HOME_DIR}"
    chmod 0755 "${HOME_DIR}" || true
}

fix_helper_permissions() {
    retro_info "Normalising helper permissions"
    chown -R root:root "${RETRO_ROOT}" "${RETRO_AI_DIR}" 2>/dev/null || true
    find "${RETRO_HELPER_DIR}" -type f -exec chmod 0755 {} +
    chmod 0755 "${RETRO_BIN_DIR}/retro" "${RETRO_AI_DIR}/retro_ai.py" 2>/dev/null || true
    chmod 0750 "${RETRO_HELPER_DIR}/retro-live-fixup" "${RETRO_HELPER_DIR}/retro-live-credentials" "${RETRO_HELPER_DIR}/retro-live-credentials"
    chmod 0755 /usr/local/sbin/retro-hwprofile
    [[ ! -f /usr/local/sbin/retro-hardware-report ]] || chmod 0755 /usr/local/sbin/retro-hardware-report
}

rebuild_initramfs() {
    retro_info "Final initramfs rebuild (all kernels)"
    mkdir -p /etc/initramfs-tools/conf.d
    cat > /etc/initramfs-tools/conf.d/retro.conf <<'EOF'
MODULES=most
COMPRESS=gzip
EOF
    cat >> /etc/initramfs-tools/modules <<'EOF'
overlay
squashfs
loop
EOF
    update-initramfs -u -k all
}

audit_packages() {
    retro_info "Auditing dpkg / apt state"
    local broken
    broken="$(dpkg --audit 2>&1 || true)"
    if [[ -n "${broken}" ]]; then
        printf '%s\n' "${broken}" >&2
        retro_die "dpkg reports half-configured packages (see above). Re-run the build with --clean or fix the failing postinst."
    fi
    apt-get check >/dev/null || retro_die "apt-get check failed - broken dependency state"
}

cleanup_chroot() {
    retro_info "Cleaning caches, logs and transient state"
    rm -f /usr/sbin/policy-rc.d
    apt-get clean
    rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/cache/debconf/*-old /var/lib/dpkg/*-old
    find /var/log -type f \( -name '*.log' -o -name '*.log.*' -o -name '*.gz' -o -name 'lastlog' -o -name 'wtmp' -o -name 'btmp' \) -exec truncate -s 0 {} + 2>/dev/null || true
    find /tmp -mindepth 1 -maxdepth 1 ! -name retro-build -exec rm -rf {} + 2>/dev/null || true
    rm -rf /root/.cache /root/.bash_history "${HOME_DIR}/.cache" "${HOME_DIR}/.bash_history"

    # Let systemd generate a fresh machine-id on first boot
    : > /etc/machine-id
    rm -f /var/lib/dbus/machine-id
    ln -sf /etc/machine-id /var/lib/dbus/machine-id

    # Remove python bytecode created while testing
    find /opt -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
}

main() {
    retro_info "=== 98_finalize.sh: start ==="
    ensure_retro_wallpaper
    sync_home_from_skel
    fix_helper_permissions
    rebuild_initramfs
    audit_packages
    cleanup_chroot
    retro_ok "=== 98_finalize.sh: complete ==="
}

main "$@"
