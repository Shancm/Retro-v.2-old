#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 - 04_installer_setup.sh   (runs as root INSIDE the build chroot)
# (replaces the former setup_calamares.sh)
#
#   * Btrfs utilities + Snapper + grub-btrfs compiled from source
#   * Calamares installer (BIOS + UEFI auto-detection through GRUB tooling)
#   * post-install hook: removes live-only pieces, wires Snapper/grub-btrfs
# =============================================================================
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/config.env"
retro_enable_traps "04_installer_setup.sh"
retro_require_chroot

export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C

CALAMARES_OK=0

# -----------------------------------------------------------------------------
# 1. Btrfs + Snapper
# -----------------------------------------------------------------------------
install_btrfs_stack() {
    retro_info "Installing Btrfs utilities, Snapper and grub-btrfs build dependencies"
    retro_apt_install btrfs-progs snapper inotify-tools gawk rsync

    retro_write /etc/snapper/config-templates/retro 0644 <<'EOF'
# Retro OS Snapper template (used by retro-post-install on Btrfs installs)
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.2"
FREE_LIMIT="0.2"
ALLOW_USERS=""
ALLOW_GROUPS="sudo"
SYNC_ACL="yes"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="10"
NUMBER_LIMIT_IMPORTANT="5"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="3"
TIMELINE_LIMIT_DAILY="5"
TIMELINE_LIMIT_WEEKLY="2"
TIMELINE_LIMIT_MONTHLY="1"
TIMELINE_LIMIT_YEARLY="0"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
EOF
}

install_grub_btrfs() {
    retro_info "Compiling grub-btrfs from source"
    local work tag tarball_url=""
    work="$(mktemp -d)"

    local -a hdr=(-H "Accept: application/vnd.github+json" -H "User-Agent: retro-os-build")
    [[ -n "${GITHUB_TOKEN:-}" ]] && hdr+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

    tag="$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 "${hdr[@]}" \
            https://api.github.com/repos/Antynea/grub-btrfs/releases/latest 2>/dev/null \
          | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null || true)"
    if [[ -z "${tag}" ]]; then
        tag="v${RETRO_GRUB_BTRFS_PIN}"
        retro_warn "GitHub API unavailable - using pinned grub-btrfs ${tag}"
    fi
    tarball_url="https://github.com/Antynea/grub-btrfs/archive/refs/tags/${tag}.tar.gz"

    if ! retro_retry 3 5 curl -fsSL --connect-timeout 15 --max-time 300 -o "${work}/gb.tar.gz" "${tarball_url}"; then
        retro_warn "Could not download grub-btrfs ${tag}; Btrfs snapshot boot entries will be unavailable"
        rm -rf "${work}"
        return 0
    fi

    tar -xzf "${work}/gb.tar.gz" -C "${work}"
    local src
    src="$(find "${work}" -maxdepth 1 -type d -name 'grub-btrfs*' | head -n1)"
    [[ -n "${src}" ]] || retro_die "grub-btrfs source directory not found in tarball"

    ( cd "${src}" && make install )

    # Debian paths for grub tooling
    if [[ -d /etc/default/grub-btrfs ]]; then
        cat >> /etc/default/grub-btrfs/config <<'EOF'

# --- Retro OS (Debian paths) ---
GRUB_BTRFS_MKCONFIG=/usr/sbin/grub-mkconfig
GRUB_BTRFS_SCRIPT_CHECK=grub-script-check
GRUB_BTRFS_GRUB_DIRNAME="/boot/grub"
EOF
    fi

    # The daemon must NOT run in the live session; retro-post-install enables it
    # on installed Btrfs systems.
    systemctl disable grub-btrfsd.service >/dev/null 2>&1 || true
    retro_ok "grub-btrfs ${tag} installed"
    rm -rf "${work}"
}

# -----------------------------------------------------------------------------
# 2. Calamares
# -----------------------------------------------------------------------------
install_calamares_packages() {
    if [[ "${RETRO_INSTALL_CALAMARES}" != "1" ]]; then
        retro_warn "RETRO_INSTALL_CALAMARES=0 - installer skipped"
        return 0
    fi
    retro_info "Installing Calamares and the GRUB toolchain (BIOS + UEFI targets side by side)"
    # -bin packages (not grub-pc / grub-efi-amd64) so both firmware targets can
    # coexist; Calamares picks the right one from /sys/firmware/efi.
    retro_apt_install grub-common grub2-common grub-pc-bin grub-efi-amd64-bin \
        os-prober efibootmgr dosfstools mtools squashfs-tools cryptsetup

    if retro_apt_install calamares calamares-settings-debian; then
        CALAMARES_OK=1
    else
        retro_warn "Calamares packages unavailable/failed - the live system will have no graphical installer"
    fi
}

write_post_install() {
    retro_info "Writing retro-post-install (executed by Calamares inside the target)"
    retro_write "${RETRO_HELPER_DIR}/retro-post-install" 0755 <<'EOF'
#!/usr/bin/env bash
# retro-post-install - runs inside the freshly installed system (Calamares
# shellprocess, chrooted). It must never fail the installation: always exit 0.
set -u
LOG="/var/log/retro-os/post-install.log"
mkdir -p "$(dirname "${LOG}")"
exec >>"${LOG}" 2>&1
echo "=== retro-post-install $(date '+%F %T') ==="

step() { echo "[post-install] $*"; }

# 1. Remove the live user once a real user exists
new_user="$(getent passwd | awk -F: '$3>=1000 && $3<65534 && $1!="retro" {print $1; exit}')"
if [[ -n "${new_user}" ]] && id -u retro >/dev/null 2>&1; then
    step "removing live user 'retro' (new user: ${new_user})"
    userdel -r retro 2>/dev/null || userdel retro 2>/dev/null || true
    rm -f /etc/sudoers.d/90-retro-nopasswd
fi

# 2. No auto-login on installed systems
step "restoring greeter-based login"
rm -f /etc/lightdm/lightdm.conf.d/50-retro-autologin.conf
cat > /etc/lightdm/lightdm.conf <<'EOT'
[LightDM]
minimum-vt=7

[Seat:*]
user-session=openbox
greeter-session=lightdm-gtk-greeter
allow-guest=false
EOT
if [[ -n "${new_user}" ]]; then
    printf '[Seat:*]\nautologin-user=\n' > /etc/lightdm/lightdm.conf.d/60-retro-installed.conf
fi

# 3. Live-only units / packages
systemctl disable retro-live-fixup.service retro-boot-report.service >/dev/null 2>&1 || true
step "purging live-boot / live-config / installer"
DEBIAN_FRONTEND=noninteractive apt-get purge -y live-boot live-boot-initramfs-tools \
    live-config live-config-systemd calamares calamares-settings-debian >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y --purge >/dev/null 2>&1 || true
rm -f /usr/share/applications/install-retro-os.desktop

step "rebuilding initramfs"
update-initramfs -u -k all || true

# 4. Btrfs: Snapper + grub-btrfs
fstype="$(stat -f -c %T / 2>/dev/null || true)"
if [[ "${fstype}" == "btrfs" ]]; then
    step "root is Btrfs - configuring Snapper and grub-btrfs"
    if command -v snapper >/dev/null 2>&1 && [[ ! -e /etc/snapper/configs/root ]]; then
        snapper --no-dbus -c root create-config -t retro / || step "snapper create-config failed"
    fi
    systemctl enable snapper-timeline.timer snapper-cleanup.timer >/dev/null 2>&1 || true
    if [[ -x /usr/bin/grub-btrfsd ]]; then
        systemctl enable grub-btrfsd.service >/dev/null 2>&1 || true
    fi
    command -v snapper >/dev/null 2>&1 && snapper --no-dbus -c root create -d "retro-os: fresh install" || true
fi

# 5. Final bootloader menu (also picks up grub-btrfs entries)
command -v update-grub >/dev/null 2>&1 && update-grub || true

step "done"
exit 0
EOF
}

configure_calamares() {
    [[ "${CALAMARES_OK}" == "1" ]] || return 0
    retro_info "Writing Calamares module overrides"
    mkdir -p /etc/calamares/modules

    retro_write /etc/calamares/modules/unpackfs.conf 0644 <<'EOF'
---
unpack:
    - source: "/run/live/medium/live/filesystem.squashfs"
      sourcefs: "squashfs"
      destination: ""
EOF

    retro_write /etc/calamares/modules/users.conf 0644 <<'EOF'
---
defaultGroups:
    - users
    - sudo
    - audio
    - video
    - plugdev
    - netdev
    - wireshark
autologinGroup: autologin
sudoersGroup: sudo
setRootPassword: false
EOF

    retro_write /etc/calamares/modules/bootloader.conf 0644 <<EOF
---
efiBootLoader: "grub"
bootloaderEntryName: "${RETRO_OS_NAME}"
grubInstall: "grub-install"
grubMkconfig: "grub-mkconfig"
grubCfg: "/boot/grub/grub.cfg"
grubProbe: "grub-probe"
efiBootMgr: "efibootmgr"
installEFIFallback: true
EOF

    retro_write /etc/calamares/modules/shellprocess_retro_cleanup.conf 0644 <<EOF
---
dontChroot: false
timeout: 900
script:
    - "${RETRO_HELPER_DIR}/retro-post-install"
EOF

    # Btrfs subvolume layout (@ and @home) - merged into the packaged mount.conf
    local mount_src=""
    for f in /etc/calamares/modules/mount.conf /usr/share/calamares/modules/mount.conf; do
        [[ -r "${f}" ]] && { mount_src="${f}"; break; }
    done
    if [[ -n "${mount_src}" ]]; then
        [[ "${mount_src}" == /etc/calamares/modules/mount.conf ]] || cp "${mount_src}" /etc/calamares/modules/mount.conf
        if ! grep -q '^btrfsSubvolumes' /etc/calamares/modules/mount.conf; then
            cat >> /etc/calamares/modules/mount.conf <<'EOF'

btrfsSubvolumes:
    - mountPoint: /
      subvolume: /@
    - mountPoint: /home
      subvolume: /@home
EOF
        fi
    else
        retro_warn "Calamares mount.conf not found - Btrfs subvolume layout left at package defaults"
    fi

    # Register the post-install shellprocess instance in settings.conf
    if [[ -r /etc/calamares/settings.conf ]]; then
        python3 - <<'PY' || retro_warn "settings.conf patch failed - installer will not run retro-post-install"
import sys
import yaml

path = "/etc/calamares/settings.conf"
with open(path, encoding="utf-8") as fh:
    cfg = yaml.safe_load(fh)

instances = cfg.get("instances") or []
if not any(i.get("id") == "retro_cleanup" for i in instances):
    instances.append({"id": "retro_cleanup", "module": "shellprocess",
                      "config": "shellprocess_retro_cleanup.conf"})
cfg["instances"] = instances

patched = False
for block in cfg.get("sequence", []):
    if "exec" in block:
        steps = block["exec"]
        if "shellprocess@retro_cleanup" not in steps:
            idx = steps.index("umount") if "umount" in steps else len(steps)
            steps.insert(idx, "shellprocess@retro_cleanup")
        patched = True
if not patched:
    sys.exit("no exec sequence found")

with open(path, "w", encoding="utf-8") as fh:
    yaml.safe_dump(cfg, fh, sort_keys=False, default_flow_style=False)
print("settings.conf patched")
PY
    else
        retro_warn "/etc/calamares/settings.conf not found (calamares-settings-debian layout changed?)"
    fi
}

main() {
    retro_info "=== 04_installer_setup.sh: start ==="
    install_btrfs_stack
    install_grub_btrfs
    install_calamares_packages
    write_post_install
    configure_calamares
    retro_ok "=== 04_installer_setup.sh: complete (calamares=${CALAMARES_OK}) ==="
}

main "$@"
