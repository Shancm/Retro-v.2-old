#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 — build.sh
# Master build script. MUST run as root on a Debian/Ubuntu host with the
# packages listed in REQUIRED_HOST_PKGS available (apt install them first,
# or let --bootstrap-host do it).
#
# Pipeline:
#   1. debootstrap minimal Debian ${DEBIAN_SUITE} chroot
#   2. run 01/02/03 (+ setup_calamares) chroot scripts
#   3. apply the overlay/ tree (retro CLI, skel configs, branding)
#   4. build the kernel/initrd, compress the chroot into squashfs (zstd)
#   5. assemble ISOLINUX (legacy BIOS) + GRUB EFI standalone (UEFI) boot trees
#   6. xorriso the final hybrid ISO + isohybrid MBR injection
#   7. sha256sum the artifact
# =============================================================================
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/config.env"

REQUIRED_HOST_PKGS=(
    debootstrap squashfs-tools xorriso isolinux syslinux-common
    syslinux-utils grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed
    mtools dosfstools zstd ca-certificates
)

trap 'retro_error "build.sh failed at line ${LINENO} (exit ${?}) — see ${RETRO_LOG_FILE:-/dev/stderr}"' ERR

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: sudo ./build.sh [options]

Options:
  --bootstrap-host   apt-get install the host-side tooling this script needs
  --clean            wipe ${BUILD_ROOT} before building
  --skip-chroot      reuse an already-populated chroot (skip debootstrap+01-03)
  -h, --help         show this help
EOF
}

BOOTSTRAP_HOST=0
CLEAN_BUILD=0
SKIP_CHROOT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bootstrap-host) BOOTSTRAP_HOST=1; shift ;;
        --clean) CLEAN_BUILD=1; shift ;;
        --skip-chroot) SKIP_CHROOT=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) retro_die "Unknown option: $1" ;;
    esac
done

require_root

chroot_mounts_active() {
    mountpoint -q "${CHROOT_DIR}/proc" 2>/dev/null
}

mount_chroot_virtfs() {
    mount --bind /dev "${CHROOT_DIR}/dev"
    mount --bind /dev/pts "${CHROOT_DIR}/dev/pts"
    mount -t proc proc "${CHROOT_DIR}/proc"
    mount -t sysfs sysfs "${CHROOT_DIR}/sys"
    cp -L /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf"
}

umount_chroot_virtfs() {
    for m in "${CHROOT_DIR}/dev/pts" "${CHROOT_DIR}/dev" "${CHROOT_DIR}/proc" "${CHROOT_DIR}/sys"; do
        umount -lf "${m}" 2>/dev/null || true
    done
}

cleanup() {
    if chroot_mounts_active; then
        umount_chroot_virtfs
    fi
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 0. Host bootstrap / clean
# -----------------------------------------------------------------------------
if [[ "${BOOTSTRAP_HOST}" -eq 1 ]]; then
    retro_info "Installing host-side build tooling"
    apt-get update -qq
    apt-get install -y --no-install-recommends "${REQUIRED_HOST_PKGS[@]}"
fi

for pkg_bin in debootstrap mksquashfs xorriso; do
    is_command "${pkg_bin}" || retro_die "Missing host tool '${pkg_bin}'. Re-run with --bootstrap-host."
done

if [[ "${CLEAN_BUILD}" -eq 1 ]]; then
    retro_info "Cleaning ${BUILD_ROOT}"
    cleanup
    rm -rf "${BUILD_ROOT}"
fi

mkdir -p "${CHROOT_DIR}" "${IMAGE_DIR}" "${ISO_DIR}" "${OUT_DIR}"

# -----------------------------------------------------------------------------
# 1. debootstrap
# -----------------------------------------------------------------------------
if [[ "${SKIP_CHROOT}" -eq 0 ]]; then
    if [[ ! -x "${CHROOT_DIR}/bin/bash" ]]; then
        retro_info "debootstrap: ${DEBIAN_SUITE} (${DEBIAN_ARCH}) → ${CHROOT_DIR}"
        debootstrap --arch="${DEBIAN_ARCH}" --variant=minbase \
            --components="$(echo "${DEBIAN_COMPONENTS}" | tr ' ' ',')" \
            "${DEBIAN_SUITE}" "${CHROOT_DIR}" "${DEBIAN_MIRROR}"
    else
        retro_info "Chroot already bootstrapped, skipping debootstrap"
    fi

    mount_chroot_virtfs

    # -------------------------------------------------------------------
    # 2. Copy config.env + scripts into the chroot and execute them
    # -------------------------------------------------------------------
    retro_info "Staging build scripts into chroot:/tmp/retro-build"
    mkdir -p "${CHROOT_DIR}/tmp/retro-build"
    cp "${SELF_DIR}/config.env" "${CHROOT_DIR}/tmp/retro-build/config.env"
    cp "${SCRIPTS_DIR}"/*.sh "${CHROOT_DIR}/tmp/retro-build/"
    chmod 755 "${CHROOT_DIR}/tmp/retro-build/"*.sh

    for step in 01_engine_setup.sh 02_interface_setup.sh 03_modules_setup.sh setup_calamares.sh; do
        retro_info "Running ${step} in chroot"
        chroot "${CHROOT_DIR}" /bin/bash "/tmp/retro-build/${step}"
    done

    # -------------------------------------------------------------------
    # 3. Apply overlay tree (retro CLI, skel configs, branding) BEFORE
    #    03's final chmod check and AFTER 02 so skel dirs already exist
    # -------------------------------------------------------------------
    retro_info "Applying overlay/ tree onto chroot"
    cp -a "${OVERLAY_DIR}/." "${CHROOT_DIR}/"
    chmod 755 "${CHROOT_DIR}/usr/local/bin/retro"
    chroot "${CHROOT_DIR}" /bin/bash -c "chown -R ${RETRO_USER}:${RETRO_USER} /home/${RETRO_USER}" || true

    rm -rf "${CHROOT_DIR}/tmp/retro-build"
    rm -f "${CHROOT_DIR}/etc/resolv.conf"

    umount_chroot_virtfs
else
    retro_info "--skip-chroot set, reusing existing chroot as-is"
fi

# -----------------------------------------------------------------------------
# 4. Build squashfs (zstd) + extract kernel/initrd
# -----------------------------------------------------------------------------
retro_info "Extracting kernel/initrd for the live boot tree"

LIVE_DIR="${IMAGE_DIR}/live"
mkdir -p "${LIVE_DIR}"

KERNEL_PATH="$(find "${CHROOT_DIR}/boot" -maxdepth 1 -name 'vmlinuz-*' | sort -V | tail -n1)"
INITRD_PATH="$(find "${CHROOT_DIR}/boot" -maxdepth 1 -name 'initrd.img-*' | sort -V | tail -n1)"
[[ -n "${KERNEL_PATH}" ]] || retro_die "No kernel found in chroot/boot — did 01_engine_setup.sh run?"
[[ -n "${INITRD_PATH}" ]] || retro_die "No initrd found in chroot/boot"

cp "${KERNEL_PATH}" "${LIVE_DIR}/vmlinuz"
cp "${INITRD_PATH}" "${LIVE_DIR}/initrd.img"

retro_info "Compressing chroot → filesystem.squashfs (zstd)"
rm -f "${LIVE_DIR}/filesystem.squashfs"
mksquashfs "${CHROOT_DIR}" "${LIVE_DIR}/filesystem.squashfs" \
    -comp zstd -Xcompression-level 19 -b 1M \
    -e boot -noappend

du -sh "${CHROOT_DIR}" "${LIVE_DIR}/filesystem.squashfs"

# -----------------------------------------------------------------------------
# 5a. ISOLINUX / Syslinux tree (legacy BIOS)
# -----------------------------------------------------------------------------
retro_info "Assembling ISOLINUX boot tree (legacy BIOS)"

ISOLINUX_DIR="${ISO_DIR}/isolinux"
mkdir -p "${ISOLINUX_DIR}"

for f in isolinux.bin ldlinux.c32 libcom32.c32 libutil.c32 vesamenu.c32; do
    found="$(find /usr/lib/ISOLINUX /usr/lib/syslinux/modules/bios -name "${f}" 2>/dev/null | head -n1)"
    [[ -n "${found}" ]] || retro_die "Missing syslinux component: ${f} (apt install isolinux syslinux-common)"
    cp "${found}" "${ISOLINUX_DIR}/"
done

cat > "${ISOLINUX_DIR}/isolinux.cfg" <<EOF
UI vesamenu.c32
DEFAULT retro_live
TIMEOUT 50
PROMPT 0
MENU TITLE ${RETRO_OS_NAME} v${RETRO_OS_VERSION}

LABEL retro_live
  MENU LABEL ${RETRO_OS_NAME} ${RETRO_OS_VERSION} — Live
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components quiet splash

LABEL retro_live_safe
  MENU LABEL ${RETRO_OS_NAME} ${RETRO_OS_VERSION} — Live (safe graphics / failsafe)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components nomodeset noapic acpi=off

LABEL retro_install
  MENU LABEL Install ${RETRO_OS_NAME} to disk (Calamares)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components quiet splash retro.install=1
EOF

# -----------------------------------------------------------------------------
# 5b. GRUB EFI standalone (UEFI fallback)
# -----------------------------------------------------------------------------
retro_info "Assembling GRUB EFI standalone boot tree (UEFI)"

EFI_BOOT_DIR="${ISO_DIR}/EFI/boot"
mkdir -p "${EFI_BOOT_DIR}" "${ISO_DIR}/boot/grub"

cat > "${ISO_DIR}/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5

menuentry "${RETRO_OS_NAME} ${RETRO_OS_VERSION} — Live (UEFI)" {
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd.img
}

menuentry "${RETRO_OS_NAME} ${RETRO_OS_VERSION} — Live (safe graphics)" {
    linux /live/vmlinuz boot=live components nomodeset noapic acpi=off
    initrd /live/initrd.img
}

menuentry "Install ${RETRO_OS_NAME} to disk (Calamares)" {
    linux /live/vmlinuz boot=live components quiet splash retro.install=1
    initrd /live/initrd.img
}
EOF

grub-mkstandalone \
    --format=x86_64-efi \
    --output="${EFI_BOOT_DIR}/bootx64.efi" \
    --locales="" --fonts="" \
    "boot/grub/grub.cfg=${ISO_DIR}/boot/grub/grub.cfg"

# Build a small FAT EFI System Partition image so the ISO is also
# directly dd-able / provides an El Torito EFI boot catalog entry.
EFI_IMG="${ISO_DIR}/boot/grub/efiboot.img"
dd if=/dev/zero of="${EFI_IMG}" bs=1M count=10 status=none
mkfs.vfat -F 16 "${EFI_IMG}" >/dev/null
mmd -i "${EFI_IMG}" ::EFI ::EFI/boot
mcopy -i "${EFI_IMG}" "${EFI_BOOT_DIR}/bootx64.efi" ::EFI/boot/bootx64.efi

# -----------------------------------------------------------------------------
# 5c. Stage /live into the iso tree
# -----------------------------------------------------------------------------
rm -rf "${ISO_DIR}/live"
cp -a "${LIVE_DIR}" "${ISO_DIR}/live"

cat > "${ISO_DIR}/.disk_info" <<EOF
${RETRO_OS_NAME} ${RETRO_OS_VERSION} "${RETRO_OS_EDITION}" — $(date -u '+%Y-%m-%d')
EOF

# -----------------------------------------------------------------------------
# 6. xorriso: build the hybrid ISO (BIOS isolinux + UEFI El Torito + isohybrid)
# -----------------------------------------------------------------------------
retro_info "Running xorriso to build the hybrid ISO"

ISOHDPFX_BIN="$(find /usr/lib/ISOLINUX /usr/lib/syslinux -name isohdpfx.bin 2>/dev/null | head -n1)"
[[ -n "${ISOHDPFX_BIN}" ]] || retro_die "isohdpfx.bin not found (apt install isolinux)"

mkdir -p "${OUT_DIR}"
OUT_ISO="${OUT_DIR}/${ISO_FILENAME}"

xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "${ISO_LABEL}" \
    -eltorito-boot isolinux/isolinux.bin \
        -eltorito-catalog isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "${ISOHDPFX_BIN}" \
    -eltorito-alt-boot \
        -e boot/grub/efiboot.img \
        -no-emul-boot -isohybrid-gpt-basdat \
    -output "${OUT_ISO}" \
    "${ISO_DIR}"

# isohybrid MBR injection is already handled by -isohybrid-mbr above for
# the BIOS path; run isohybrid explicitly too for maximum USB-dd compatibility.
if is_command isohybrid; then
    isohybrid --uefi "${OUT_ISO}" || retro_warn "isohybrid post-pass failed (ISO may already be hybrid via xorriso)"
fi

# -----------------------------------------------------------------------------
# 7. Checksum
# -----------------------------------------------------------------------------
retro_info "Generating SHA-256 checksum"
( cd "${OUT_DIR}" && sha256sum "${ISO_FILENAME}" > "${ISO_FILENAME}.sha256" )

retro_ok "Build complete: ${OUT_ISO}"
retro_ok "Checksum:       ${OUT_ISO}.sha256"
du -h "${OUT_ISO}"
