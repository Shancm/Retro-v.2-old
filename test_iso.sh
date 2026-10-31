#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 - test_iso.sh   (automated QEMU verification, no root needed)
#
#   ./test_iso.sh [ISO] [--bios] [--uefi] [--low] [--std] [--report] [--usb]
#                       [--timeout SEC] [--no-kvm] [--quiet] [--keep]
#
#   --bios / --uefi   firmware under test (default: both)
#   --low  / --std    768 MiB (low tier) / 2048 MiB (standard tier) guest
#                     default: BIOS -> low, UEFI -> std
#   --report          boot with retro.report=1 + serial console, parse the
#                     markers printed by retro-boot-report and print a scorecard
#   --usb             attach the ISO as a USB disk (tests the isohybrid MBR/GPT)
#
# What it proves: the bootloader chain (ISOLINUX or standalone GRUB-EFI) starts
# the kernel, live-boot mounts the squashfs, LightDM auto-logs in (no login
# loop), Openbox + Tint2 run, the correct tier/ZRAM were chosen, and the screen
# is not black (framebuffer screenshot analysis).
# =============================================================================
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RETRO_CONTEXT=host
# shellcheck source=config.env
source "${SELF_DIR}/config.env"

ISO_PATH="${OUT_DIR}/${ISO_FILENAME}"
WANT_BIOS=0
WANT_UEFI=0
WANT_LOW=0
WANT_STD=0
OPT_REPORT=0
OPT_USB=0
OPT_KVM=1
OPT_QUIET=0
OPT_KEEP=0
TIMEOUT_OVERRIDE=""

REPORT_ARGS="retro.report=1 console=tty0 console=ttyS0,115200n8 loglevel=6 systemd.show_status=1"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    T_G=$'\033[32m'; T_R=$'\033[31m'; T_Y=$'\033[33m'; T_C=$'\033[36m'; T_B=$'\033[1m'; T_D=$'\033[2m'; T_0=$'\033[0m'
else
    T_G=""; T_R=""; T_Y=""; T_C=""; T_B=""; T_D=""; T_0=""
fi

info() { printf '%s[*]%s %s\n' "${T_C}" "${T_0}" "$*"; }
ok()   { printf '%s[+]%s %s\n' "${T_G}" "${T_0}" "$*"; }
warn() { printf '%s[!]%s %s\n' "${T_Y}" "${T_0}" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "${T_R}" "${T_0}" "$*" >&2; }
die()  { err "$*"; exit 2; }

QEMU_PID=""
LOG_ROOT=""
OVMF_CODE="" OVMF_VARS="" OVMF_BIOS=""
HAVE_PY=0
USE_KVM=0
TOTAL_REQ_FAIL=0
declare -a SUMMARY=()

usage() {
    sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bios)    WANT_BIOS=1 ;;
            --uefi)    WANT_UEFI=1 ;;
            --low)     WANT_LOW=1 ;;
            --std)     WANT_STD=1 ;;
            --report)  OPT_REPORT=1 ;;
            --usb)     OPT_USB=1 ;;
            --no-kvm)  OPT_KVM=0 ;;
            --quiet)   OPT_QUIET=1 ;;
            --keep)    OPT_KEEP=1 ;;
            --timeout) TIMEOUT_OVERRIDE="${2:-}"; shift ;;
            -h|--help) usage; exit 0 ;;
            -*)        usage >&2; die "unknown option: $1" ;;
            *)         ISO_PATH="$1" ;;
        esac
        shift
    done
    if (( ! WANT_BIOS && ! WANT_UEFI )); then WANT_BIOS=1; WANT_UEFI=1; fi
    if [[ -n "${TIMEOUT_OVERRIDE}" && ! "${TIMEOUT_OVERRIDE}" =~ ^[0-9]+$ ]]; then
        die "--timeout needs a number of seconds"
    fi
}

# -----------------------------------------------------------------------------
# Environment
# -----------------------------------------------------------------------------
find_ovmf() {
    local code vars
    for code in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
                /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
                /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/qemu/OVMF_CODE.fd; do
        [[ -f "${code}" ]] || continue
        vars="${code/CODE/VARS}"
        if [[ -f "${vars}" ]]; then OVMF_CODE="${code}"; OVMF_VARS="${vars}"; return 0; fi
    done
    for code in /usr/share/ovmf/OVMF.fd /usr/share/qemu/OVMF.fd /usr/share/OVMF/OVMF.fd; do
        if [[ -f "${code}" ]]; then OVMF_BIOS="${code}"; return 0; fi
    done
    return 1
}

check_environment() {
    command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 not found (apt install qemu-system-x86)"
    [[ -f "${ISO_PATH}" ]] || die "ISO not found: ${ISO_PATH} (build it first: sudo ./build.sh)"
    if command -v python3 >/dev/null 2>&1; then HAVE_PY=1; else warn "python3 missing: no screenshot analysis, QEMU will be killed instead of asked to quit"; fi

    if (( WANT_UEFI )); then
        find_ovmf || die "OVMF firmware not found (apt install ovmf)"
        info "UEFI firmware: ${OVMF_CODE:-${OVMF_BIOS}}"
    fi
    if (( OPT_REPORT )); then
        command -v xorriso >/dev/null 2>&1 || die "--report patches the boot menus of a temporary ISO copy and needs xorriso"
    fi

    if (( OPT_KVM )) && [[ -r /dev/kvm && -w /dev/kvm ]]; then
        USE_KVM=1
        ok "KVM acceleration available"
    else
        warn "no usable /dev/kvm (or --no-kvm): falling back to TCG emulation - boots are 5-10x slower"
    fi

    if [[ -f "${ISO_PATH}.sha256" ]]; then
        if ( cd "$(dirname "${ISO_PATH}")" && sha256sum --status -c "$(basename "${ISO_PATH}").sha256" ); then
            ok "ISO checksum verified"
        else
            die "ISO does not match ${ISO_PATH}.sha256 - rebuild or re-download it"
        fi
    fi

    local base="${OUT_DIR}"
    if ! mkdir -p "${base}/test-logs" 2>/dev/null || [[ ! -w "${base}/test-logs" ]]; then
        base="${SELF_DIR}"
        mkdir -p "${base}/test-logs"
    fi
    LOG_ROOT="${base}/test-logs/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "${LOG_ROOT}"
    info "logs: ${LOG_ROOT}"
}

cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
        kill -KILL "${QEMU_PID}" 2>/dev/null || true
    fi
    exit "${rc}"
}

# -----------------------------------------------------------------------------
# Derived ISO for --report (real boot chain, kernel args appended)
# -----------------------------------------------------------------------------
make_report_iso() {   # <src> <dst> <tmpdir>
    local src="$1" dst="$2" tmp="$3"
    mkdir -p "${tmp}"
    xorriso -osirrox on -indev "${src}" \
        -extract /isolinux/isolinux.cfg "${tmp}/isolinux.cfg" \
        -extract /boot/grub/grub.cfg "${tmp}/grub.cfg" >"${tmp}/xorriso-extract.log" 2>&1 \
        || die "could not extract boot configs from the ISO (see ${tmp}/xorriso-extract.log)"

    # ISOLINUX: append to the default entry and shorten the menu timeout
    sed -i \
        -e "/^LABEL live\$/,/^\$/ s|^\\(  APPEND .*\\)\$|\\1 ${REPORT_ARGS}|" \
        -e 's|^TIMEOUT .*|TIMEOUT 10|' "${tmp}/isolinux.cfg"
    # GRUB: same for the default menuentry
    sed -i \
        -e "/--id live {/,/^}/ s|^\\([[:space:]]*linux .*\\)\$|\\1 ${REPORT_ARGS}|" \
        -e 's|^set timeout=.*|set timeout=1|' "${tmp}/grub.cfg"

    grep -q 'retro.report=1' "${tmp}/isolinux.cfg" || die "failed to patch isolinux.cfg (menu layout changed?)"
    grep -q 'retro.report=1' "${tmp}/grub.cfg"     || die "failed to patch grub.cfg (menu layout changed?)"

    xorriso -indev "${src}" -outdev "${dst}" -boot_image any replay -overwrite on \
        -map "${tmp}/isolinux.cfg" /isolinux/isolinux.cfg \
        -map "${tmp}/grub.cfg" /boot/grub/grub.cfg -commit >"${tmp}/xorriso-repack.log" 2>&1 \
        || die "could not repack the report ISO (see ${tmp}/xorriso-repack.log)"
    [[ -s "${dst}" ]] || die "report ISO is empty"
}

# -----------------------------------------------------------------------------
# QEMU helpers
# -----------------------------------------------------------------------------
qemu_monitor() {   # <socket> <command> [wait-seconds]
    (( HAVE_PY )) || return 1
    python3 - "$1" "$2" "${3:-1}" <<'PY'
import socket
import sys
import time

path, cmd, wait = sys.argv[1], sys.argv[2], float(sys.argv[3])
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(path)
time.sleep(0.3)
try:
    s.recv(65536)
except OSError:
    pass
s.sendall((cmd + "\n").encode())
time.sleep(wait)
try:
    s.recv(65536)
except OSError:
    pass
s.close()
PY
}

analyse_screen() {   # <ppm> <png>  -> KEY=VALUE lines
    python3 - "$1" "$2" <<'PY'
import struct
import sys
import zlib

src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
pos = 0
fields = []
while len(fields) < 4:
    while data[pos:pos + 1].isspace():
        pos += 1
    if data[pos:pos + 1] == b"#":
        while data[pos:pos + 1] != b"\n":
            pos += 1
        continue
    start = pos
    while not data[pos:pos + 1].isspace():
        pos += 1
    fields.append(data[start:pos])
if fields[0] != b"P6":
    sys.exit("not a P6 PPM")
w, h = int(fields[1]), int(fields[2])
pix = data[pos + 1:]
total = w * h
step = max(1, total // 250000)
nonblack = colors_n = 0
colors = set()
luma = 0
count = 0
for idx in range(0, total, step):
    r, g, b = pix[idx * 3], pix[idx * 3 + 1], pix[idx * 3 + 2]
    count += 1
    if r + g + b > 30:
        nonblack += 1
    colors.add((r >> 4, g >> 4, b >> 4))
    luma += (r * 299 + g * 587 + b * 114) // 1000
print("WIDTH=%d" % w)
print("HEIGHT=%d" % h)
print("NONBLACK_PCT=%d" % (100 * nonblack // max(count, 1)))
print("COLORS=%d" % len(colors))
print("MEAN_LUMA=%d" % (luma // max(count, 1)))


def chunk(tag, body):
    blob = tag + body
    return struct.pack(">I", len(body)) + blob + struct.pack(">I", zlib.crc32(blob) & 0xFFFFFFFF)


raw = b"".join(b"\x00" + pix[y * w * 3:(y + 1) * w * 3] for y in range(h))
png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
with open(dst, "wb") as fh:
    fh.write(png)
PY
}

strip_serial() {   # <raw> <clean>
    sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r//g' "$1" > "$2"
}

# -----------------------------------------------------------------------------
# Scorecard
# -----------------------------------------------------------------------------
REQ_PASS=0
REQ_FAIL=0
ADV_WARN=0

row() {   # <status> <label> <detail>
    local colour="${T_G}"
    case "$1" in
        FAIL) colour="${T_R}" ;;
        WARN) colour="${T_Y}" ;;
    esac
    printf '  %s[ %-4s ]%s %-34s %s\n' "${colour}" "$1" "${T_0}" "$2" "$3"
}

req_check() {   # <label> <actual> <expected-description> <ok:0|1>
    if [[ "$4" == "1" ]]; then
        REQ_PASS=$(( REQ_PASS + 1 )); row PASS "$1" "$2"
    else
        REQ_FAIL=$(( REQ_FAIL + 1 )); row FAIL "$1" "$2   (expected ${3})"
    fi
}

adv_check() {
    if [[ "$4" == "1" ]]; then
        row PASS "$1" "$2"
    else
        ADV_WARN=$(( ADV_WARN + 1 )); row WARN "$1" "$2   (expected ${3})"
    fi
}

diagnose() {   # <clean-log> <reason>
    local log="$1" reason="$2"
    printf '\n%s  Boot diagnosis%s (reason: %s)\n' "${T_B}" "${T_0}" "${reason}"
    if ! grep -q 'Linux version' "${log}"; then
        printf '   - no kernel output on the serial console: the bootloader did not start the kernel,\n'
        printf '     or this ISO has no serial-capable entry. Re-run with --report, or look at the VGA screen (drop --quiet).\n'
    fi
    if grep -qE 'Kernel panic' "${log}"; then
        printf '   - KERNEL PANIC:\n'; grep -B2 -A4 'Kernel panic' "${log}" | head -n 14 | sed 's/^/       /'
        printf '     usually: live-boot cannot find /live/filesystem.squashfs (wrong media/label) or initramfs lacks storage drivers.\n'
    fi
    if grep -qE 'emergency mode|Give root password' "${log}"; then
        printf '   - systemd dropped to EMERGENCY MODE (a mandatory unit/mount failed).\n'
    fi
    local cmdline
    cmdline="$(grep -m1 -E 'Kernel command line:|Command line:' "${log}" || true)"
    [[ -z "${cmdline}" ]] || printf '   - %s\n' "${cmdline#*] }"
    if [[ "${reason}" == "timeout" ]] && grep -q 'Linux version' "${log}" && ! grep -q 'RETRO_REPORT_BEGIN' "${log}"; then
        printf '   - kernel booted but retro-boot-report never ran: retro.report=1 missing from the cmdline,\n'
        printf '     the system is too slow (try --timeout, KVM), or graphical.target was not reached.\n'
    fi
    local failed
    failed="$(grep -E '\[FAILED\]|Failed to start' "${log}" | head -n 12 || true)"
    if [[ -n "${failed}" ]]; then
        printf '   - failing units:\n'; printf '%s\n' "${failed}" | sed 's/^/       /'
    fi
    printf '   - last serial lines:\n'; tail -n 15 "${log}" | sed 's/^/       /'
}

evaluate_run() {   # <clean-log> <expected-tier> <reason> <screen-stats-file>
    local log="$1" tier="$2" reason="$3" stats="$4"
    local -A KV=()
    local -a DETAIL=()
    local line key

    while IFS= read -r line; do
        if [[ "${line}" =~ RETRO_TEST:\ ([A-Za-z0-9_]+)=(.*)$ ]]; then
            KV["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        elif [[ "${line}" =~ RETRO_DETAIL:\ (.*)$ ]]; then
            DETAIL+=("${BASH_REMATCH[1]}")
        fi
    done < "${log}"

    local got_report=0
    grep -q 'RETRO_REPORT_DONE' "${log}" && got_report=1

    REQ_PASS=0; REQ_FAIL=0; ADV_WARN=0
    printf '\n%s  Scorecard%s\n' "${T_B}" "${T_0}"

    req_check "Boot report received" "${reason}" "RETRO_REPORT_DONE" "${got_report}"
    if (( got_report == 0 )); then
        diagnose "${log}" "${reason}"
        TOTAL_REQ_FAIL=$(( TOTAL_REQ_FAIL + REQ_FAIL ))
        SUMMARY+=("${T_R}FAIL${T_0}  no report (${reason})")
        return
    fi

    local v
    v="${KV[LOGIN_LOOP_SUSPECT]:-n/a}"
    req_check "No login loop" "LOGIN_LOOP_SUSPECT=${v}" "0" "$([[ "${v}" == "0" ]] && echo 1 || echo 0)"
    v="${KV[AUTOLOGIN_SESSION]:-n/a}"
    req_check "Autologin desktop session" "AUTOLOGIN_SESSION=${v}" "yes" "$([[ "${v}" == "yes" ]] && echo 1 || echo 0)"
    v="${KV[PROC_openbox]:-n/a}"
    req_check "Window manager (openbox)" "PROC_openbox=${v}" "yes" "$([[ "${v}" == "yes" ]] && echo 1 || echo 0)"
    v="${KV[PROC_tint2]:-n/a}"
    req_check "Panel (tint2)" "PROC_tint2=${v}" "yes" "$([[ "${v}" == "yes" ]] && echo 1 || echo 0)"
    v="${KV[TIER]:-n/a}"
    req_check "Adaptive tier (${KV[RAM_MB]:-?} MiB seen)" "TIER=${v}" "${tier}" "$([[ "${v}" == "${tier}" ]] && echo 1 || echo 0)"
    v="${KV[ZRAM]:-n/a}"
    req_check "ZRAM initialised" "ZRAM=${v}" "1" "$([[ "${v}" =~ ^[0-9]+$ && "${v}" -ge 1 ]] && echo 1 || echo 0)"

    # Graphics integrity from the framebuffer screenshot
    if [[ -s "${stats}" ]]; then
        local nb colors
        nb="$(sed -n 's/^NONBLACK_PCT=//p' "${stats}")"; colors="$(sed -n 's/^COLORS=//p' "${stats}")"
        req_check "Graphics integrity (screenshot)" "non-black ${nb}%, ${colors} colour buckets, $(sed -n 's/^WIDTH=//p' "${stats}")x$(sed -n 's/^HEIGHT=//p' "${stats}")" \
            ">=40% non-black and >=4 colour buckets" "$([[ "${nb}" -ge 40 && "${colors}" -ge 4 ]] && echo 1 || echo 0)"
    else
        warn "no screenshot available - graphics integrity not judged"
    fi

    printf '\n%s  Supporting checks (advisory)%s\n' "${T_D}" "${T_0}"
    local exp_picom="expected-stopped" exp_proc="no"
    [[ "${tier}" == "standard" ]] && { exp_picom="expected-running"; exp_proc="yes"; }
    adv_check "LightDM active"        "LIGHTDM_ACTIVE=${KV[LIGHTDM_ACTIVE]:-n/a}" "active" "$([[ "${KV[LIGHTDM_ACTIVE]:-}" == "active" ]] && echo 1 || echo 0)"
    adv_check "Xorg running"          "XORG_RUNNING=${KV[XORG_RUNNING]:-n/a}"     "yes"    "$([[ "${KV[XORG_RUNNING]:-}" == "yes" ]] && echo 1 || echo 0)"
    adv_check "Xorg (EE) errors"      "XORG_ERRORS=${KV[XORG_ERRORS]:-n/a}"       "0"      "$([[ "${KV[XORG_ERRORS]:-x}" == "0" ]] && echo 1 || echo 0)"
    adv_check "Desktop (pcmanfm)"     "PROC_pcmanfm=${KV[PROC_pcmanfm]:-n/a}"     "yes"    "$([[ "${KV[PROC_pcmanfm]:-}" == "yes" ]] && echo 1 || echo 0)"
    adv_check "Tray: nm-applet"       "PROC_nm_applet=${KV[PROC_nm_applet]:-n/a}" "yes"    "$([[ "${KV[PROC_nm_applet]:-}" == "yes" ]] && echo 1 || echo 0)"
    adv_check "Tray: volumeicon"      "PROC_volumeicon=${KV[PROC_volumeicon]:-n/a}" "yes"  "$([[ "${KV[PROC_volumeicon]:-}" == "yes" ]] && echo 1 || echo 0)"
    adv_check "Wallpaper installed"   "WALLPAPER=${KV[WALLPAPER]:-n/a}"           "yes"    "$([[ "${KV[WALLPAPER]:-}" == "yes" ]] && echo 1 || echo 0)"
    adv_check "Compositor policy"     "${KV[PICOM_POLICY]:-n/a}, picom=${KV[PROC_picom]:-n/a}" "${exp_picom}, picom=${exp_proc}" \
        "$([[ "${KV[PICOM_POLICY]:-}" == "${exp_picom}" && "${KV[PROC_picom]:-}" == "${exp_proc}" ]] && echo 1 || echo 0)"
    adv_check "EarlyOOM active"       "EARLYOOM_ACTIVE=${KV[EARLYOOM_ACTIVE]:-n/a}" "active" "$([[ "${KV[EARLYOOM_ACTIVE]:-}" == "active" ]] && echo 1 || echo 0)"
    if [[ "${tier}" == "low" ]]; then
        adv_check "EarlyOOM thresholds"  "${KV[EARLYOOM_ARGS]:-n/a}" "-m 4 -s 8" "$([[ "${KV[EARLYOOM_ARGS]:-}" == "-m 4 -s 8"* ]] && echo 1 || echo 0)"
        adv_check "vm.swappiness"        "SWAPPINESS=${KV[SWAPPINESS]:-n/a}" "100" "$([[ "${KV[SWAPPINESS]:-}" == "100" ]] && echo 1 || echo 0)"
    fi
    adv_check "TCP congestion = bbr"  "BBR=${KV[BBR]:-n/a}"                      "bbr"    "$([[ "${KV[BBR]:-}" == "bbr" ]] && echo 1 || echo 0)"
    adv_check "systemd state"         "SYSTEM_STATE=${KV[SYSTEM_STATE]:-n/a}"    "running" "$([[ "${KV[SYSTEM_STATE]:-}" == "running" ]] && echo 1 || echo 0)"
    adv_check "No failed units"       "FAILED_UNITS=${KV[FAILED_UNITS]:-n/a}"    "0"      "$([[ "${KV[FAILED_UNITS]:-x}" == "0" ]] && echo 1 || echo 0)"
    adv_check "retro CLI works"       "RETRO_CLI=${KV[RETRO_CLI]:-n/a}"          "yes"    "$([[ "${KV[RETRO_CLI]:-}" == "yes" ]] && echo 1 || echo 0)"
    for key in $(printf '%s\n' "${!KV[@]}" | grep '^TOOL_' | sort); do
        adv_check "tool ${key#TOOL_}" "${KV[${key}]}" "ok" "$([[ "${KV[${key}]}" == "ok" ]] && echo 1 || echo 0)"
    done

    if (( REQ_FAIL > 0 || ADV_WARN > 0 )) && (( ${#DETAIL[@]} > 0 )); then
        printf '\n%s  Details from the guest%s\n' "${T_D}" "${T_0}"
        printf '       %s\n' "${DETAIL[@]}"
    fi

    printf '\n  Required: %s%d passed%s, %s%d failed%s | advisory warnings: %d\n' \
        "${T_G}" "${REQ_PASS}" "${T_0}" "${T_R}" "${REQ_FAIL}" "${T_0}" "${ADV_WARN}"
    TOTAL_REQ_FAIL=$(( TOTAL_REQ_FAIL + REQ_FAIL ))
    if (( REQ_FAIL == 0 )); then
        SUMMARY+=("${T_G}PASS${T_0}  required ${REQ_PASS}/${REQ_PASS}, ${ADV_WARN} advisory warning(s)")
    else
        SUMMARY+=("${T_R}FAIL${T_0}  ${REQ_FAIL} required check(s) failed")
    fi
}

# -----------------------------------------------------------------------------
# One QEMU run
# -----------------------------------------------------------------------------
run_one() {   # <mode: bios|uefi> <ram_mb> <expected-tier>
    local mode="$1" ram="$2" tier="$3"
    local label="${mode}-${ram}M"
    local dir="${LOG_ROOT}/${label}"
    local sock="${dir}/monitor.sock"
    local raw="${dir}/serial.log" clean="${dir}/serial.clean.log"
    local iso="${ISO_PATH}" smp=2 timeout reason="" qpid t0 now
    mkdir -p "${dir}"
    (( ram <= 1024 )) && smp=1

    printf '\n%s=== %s | %d MiB | %d vCPU | expect tier=%s | %s ===%s\n' \
        "${T_B}" "${mode^^}" "${ram}" "${smp}" "${tier}" "$([[ ${OPT_REPORT} -eq 1 ]] && echo report-mode || echo visual-mode)" "${T_0}"

    if (( OPT_REPORT )); then
        info "building report ISO (retro.report=1 + serial console appended to the default entry)"
        make_report_iso "${ISO_PATH}" "${dir}/report.iso" "${dir}/patch"
        iso="${dir}/report.iso"
    fi

    local -a q=(qemu-system-x86_64 -name "retro-test-${label}" -m "${ram}M" -smp "${smp}" -vga std
                -display none -serial stdio -monitor "unix:${sock},server,nowait" -no-reboot
                -netdev user,id=n0 -device virtio-net-pci,netdev=n0)
    if (( USE_KVM )); then q+=(-enable-kvm -cpu host); else q+=(-accel tcg -cpu max); fi

    if [[ "${mode}" == "bios" ]]; then
        q+=(-machine pc)
    else
        q+=(-machine q35)
        if [[ -n "${OVMF_CODE}" ]]; then
            cp -f "${OVMF_VARS}" "${dir}/OVMF_VARS.fd"
            q+=(-drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" -drive "if=pflash,format=raw,file=${dir}/OVMF_VARS.fd")
        else
            q+=(-bios "${OVMF_BIOS}")
        fi
    fi

    if (( OPT_USB )); then
        info "attaching the ISO as a USB disk (isohybrid test)"
        q+=(-drive "if=none,id=stick,format=raw,readonly=on,file=${iso}" -device qemu-xhci,id=xhci
            -device usb-storage,bus=xhci.0,drive=stick,bootindex=1)
    elif [[ "${mode}" == "bios" ]]; then
        q+=(-cdrom "${iso}" -boot d)
    else
        q+=(-cdrom "${iso}")
    fi

    if [[ -n "${TIMEOUT_OVERRIDE}" ]]; then
        timeout="${TIMEOUT_OVERRIDE}"
    elif (( USE_KVM )); then
        timeout=300
    else
        timeout=1200
    fi

    printf '%s\n' "${q[*]}" > "${dir}/qemu-command.txt"
    info "serial console -> ${raw}  (timeout ${timeout}s)"

    if (( OPT_QUIET )); then
        "${q[@]}" < /dev/null > "${raw}" 2>&1 &
    else
        "${q[@]}" < /dev/null > >(tee "${raw}" | sed -u -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r//g' -e 's/^/    [serial] /') 2>&1 &
    fi
    qpid=$!
    QEMU_PID="${qpid}"

    t0="$(date +%s)"
    while kill -0 "${qpid}" 2>/dev/null; do
        if grep -aq 'RETRO_REPORT_DONE' "${raw}" 2>/dev/null; then reason="done"; break; fi
        if grep -aqE 'Kernel panic - not syncing' "${raw}" 2>/dev/null; then reason="kernel-panic"; break; fi
        if grep -aqE 'You are in emergency mode|Welcome to emergency mode|Give root password for maintenance' "${raw}" 2>/dev/null; then reason="emergency-mode"; break; fi
        now="$(date +%s)"
        if (( now - t0 >= timeout )); then reason="timeout"; break; fi
        sleep 3
    done
    [[ -n "${reason}" ]] || reason="qemu-exited"
    ok "stopped waiting after $(( $(date +%s) - t0 ))s (${reason})"

    local stats=""
    if kill -0 "${qpid}" 2>/dev/null && (( HAVE_PY )) && [[ -S "${sock}" ]]; then
        sleep 2
        qemu_monitor "${sock}" "screendump ${dir}/screen.ppm" 2 || warn "screendump command failed"
        if [[ -s "${dir}/screen.ppm" ]]; then
            if analyse_screen "${dir}/screen.ppm" "${dir}/screen.png" > "${dir}/screen.stats" 2>"${dir}/screen.err"; then
                stats="${dir}/screen.stats"
                info "screenshot: ${dir}/screen.png"
            else
                warn "screenshot analysis failed: $(cat "${dir}/screen.err")"
            fi
        else
            warn "QEMU produced no screendump"
        fi
        qemu_monitor "${sock}" "quit" 1 || true
    fi
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "${qpid}" 2>/dev/null || break
        sleep 1
    done
    kill -KILL "${qpid}" 2>/dev/null || true
    wait "${qpid}" 2>/dev/null || true
    QEMU_PID=""

    strip_serial "${raw}" "${clean}"
    if (( OPT_REPORT )); then
        evaluate_run "${clean}" "${tier}" "${reason}" "${stats}"
        (( OPT_KEEP )) || rm -f "${dir}/report.iso"
    else
        evaluate_visual "${clean}" "${reason}" "${stats}"
    fi
    SUMMARY[${#SUMMARY[@]}-1]="$(printf '%-6s %5sM  tier=%-8s ' "${mode^^}" "${ram}" "${tier}")${SUMMARY[${#SUMMARY[@]}-1]}"
}

# Visual mode (no --report): only the screenshot and boot progress are judged
evaluate_visual() {   # <clean-log> <reason> <stats>
    local log="$1" reason="$2" stats="$3" fails=0
    printf '\n%s  Visual check%s (run with --report for the full scorecard)\n' "${T_B}" "${T_0}"
    if [[ -s "${stats}" ]]; then
        local nb colors
        nb="$(sed -n 's/^NONBLACK_PCT=//p' "${stats}")"; colors="$(sed -n 's/^COLORS=//p' "${stats}")"
        if [[ "${nb}" -ge 40 && "${colors}" -ge 4 ]]; then
            row PASS "Graphics integrity (screenshot)" "non-black ${nb}%, ${colors} colour buckets"
        else
            row FAIL "Graphics integrity (screenshot)" "non-black ${nb}%, ${colors} colour buckets (black/blank screen?)"
            fails=1
        fi
    else
        row WARN "Graphics integrity (screenshot)" "unavailable (python3 or QEMU monitor missing)"
        fails=1
    fi
    TOTAL_REQ_FAIL=$(( TOTAL_REQ_FAIL + fails ))
    if (( fails == 0 )); then SUMMARY+=("${T_G}PASS${T_0}  desktop visible"); else SUMMARY+=("${T_R}FAIL${T_0}  see screenshot + serial log"); fi
    : "${log}${reason}"
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_environment
    trap cleanup EXIT

    local -a runs=()
    local mode
    for mode in bios uefi; do
        if [[ "${mode}" == "bios" && ${WANT_BIOS} -eq 0 ]]; then continue; fi
        if [[ "${mode}" == "uefi" && ${WANT_UEFI} -eq 0 ]]; then continue; fi
        if (( ! WANT_LOW && ! WANT_STD )); then
            if [[ "${mode}" == "bios" ]]; then runs+=("bios:768:low"); else runs+=("uefi:2048:standard"); fi
        else
            (( WANT_LOW )) && runs+=("${mode}:768:low")
            (( WANT_STD )) && runs+=("${mode}:2048:standard")
        fi
    done

    local r m ram tier
    for r in "${runs[@]}"; do
        IFS=: read -r m ram tier <<< "${r}"
        run_one "${m}" "${ram}" "${tier}"
    done

    printf '\n%s================ TEST SUMMARY ================%s\n' "${T_B}" "${T_0}"
    local s
    for s in "${SUMMARY[@]}"; do printf '  %s\n' "${s}"; done
    printf '  logs: %s\n\n' "${LOG_ROOT}"

    if (( TOTAL_REQ_FAIL > 0 )); then
        err "${TOTAL_REQ_FAIL} required check(s) failed"
        exit 1
    fi
    ok "all required checks passed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
