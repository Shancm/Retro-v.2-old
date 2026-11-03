#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 - 03_modules_setup.sh   (runs as root INSIDE the build chroot)
#
#   * classic auditing tools (apt)
#   * modern Go/Rust binaries staged into /usr/local/bin via retro-fetch-tools
#   * Retro AI daemon service (payload: /opt/retro-ai/retro_ai.py from overlay)
#   * boot health reporter used by test_iso.sh
#   * final menu regeneration
# =============================================================================
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/config.env"
retro_enable_traps "03_modules_setup.sh"
retro_require_chroot

export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C

# -----------------------------------------------------------------------------
# 1. Classic tools
# -----------------------------------------------------------------------------
install_classic_tools() {
    retro_info "Preseeding wireshark-common (non-root capture via group 'wireshark')"
    echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections

    retro_info "Installing classic auditing tools (CLI + GUI)"
    retro_apt_install \
        nmap wireshark tshark aircrack-ng hydra john nikto sqlmap wifite \
        tcpdump netcat-openbsd dnsutils whois traceroute libpcap0.8 iw

    # John the Ripper CLI is mandatory; GUI tools and ffuf are optional.
    retro_apt_install_optional john-data johnny ffuf

    # Hydra GUI (XHydra) & Nmap GUI (NmapSI4) & Gufw Firewall
    retro_apt_install_optional xhydra nmapsi4 gufw etherape

    # /usr/sbin/john സിംലിങ്ക്
    if [[ -x /usr/sbin/john ]]; then
        ln -sf /usr/sbin/john /usr/local/bin/john
    fi

    # Rockyou / Wordlists സജ്ജീകരണം
    retro_info "Setting up security wordlists (rockyou)"
    retro_apt_install_optional wordlists
    if [[ -f /usr/share/wordlists/rockyou.txt.gz ]] && [[ ! -f /usr/share/wordlists/rockyou.txt ]]; then
        gzip -dc /usr/share/wordlists/rockyou.txt.gz > /usr/share/wordlists/rockyou.txt || true
    fi

    getent group wireshark >/dev/null || groupadd --system wireshark
    usermod -aG wireshark "${RETRO_USER}"
}

# -----------------------------------------------------------------------------
# 2. Modern Go/Rust tools: standalone fetcher (also used by `retro update --tools`)
# -----------------------------------------------------------------------------
write_fetcher() {
    retro_info "Installing retro-fetch-tools"
    retro_write "${RETRO_ETC_DIR}/tools.conf" 0644 <<EOF
# Retro OS modern tool staging (read by retro-fetch-tools)
RETRO_TOOLS_CHANNEL="${RETRO_TOOLS_CHANNEL}"
RETRO_TOOLS_STRICT="${RETRO_TOOLS_STRICT}"
RETRO_PIN_RUSTSCAN="${RETRO_PIN_RUSTSCAN}"
RETRO_PIN_FFUF="${RETRO_PIN_FFUF}"
RETRO_PIN_HTTPX="${RETRO_PIN_HTTPX}"
RETRO_PIN_NAABU="${RETRO_PIN_NAABU}"
EOF

    retro_write "${RETRO_HELPER_DIR}/retro-fetch-tools" 0755 <<'EOF'
#!/usr/bin/env bash
# retro-fetch-tools - stage pre-compiled Go/Rust auditing binaries into /usr/local/bin
#
#   retro-fetch-tools --all | rustscan ffuf httpx naabu   [--strict]
#   retro-fetch-tools --list
#
# Resolution order per tool:
#   1. GitHub "latest" release (channel=latest)       -> asset chosen by regex
#   2. GitHub release for the pinned version          -> asset chosen by regex
#   3. direct download URL for the pinned version     -> no API needed
# Integrity: GitHub artifact attestation is mandatory and the release checksum
# must also match. A checksum published beside an asset is not trusted alone.
# GITHUB_TOKEN (optional) lifts the anonymous API rate limit.
set -Eeuo pipefail

CONF="/etc/retro-os/tools.conf"
# shellcheck source=/dev/null
[[ -r "${CONF}" ]] && source "${CONF}"

CHANNEL="${RETRO_TOOLS_CHANNEL:-latest}"
STRICT="${RETRO_TOOLS_STRICT:-0}"
DEST="${RETRO_TOOLS_DEST:-/usr/local/bin}"
MANIFEST="${RETRO_TOOLS_MANIFEST:-/etc/retro-os/modern-tools.manifest}"
ALL_TOOLS=(rustscan ffuf httpx naabu)

log()  { printf '[retro-fetch-tools] %s\n' "$*"; }
warn() { printf '[retro-fetch-tools] WARN: %s\n' "$*" >&2; }

REPO="" BIN="" PIN="" TAG_PREFIX="" ASSET_RES="" PIN_ASSET=""

tool_meta() {
    case "$1" in
        rustscan)
            REPO="bee-san/RustScan"; BIN="rustscan"; PIN="${RETRO_PIN_RUSTSCAN:-2.3.0}"; TAG_PREFIX=""
            ASSET_RES='(_amd64\.deb$|x86_64-linux.*\.(zip|tar\.gz|tar\.gz\.zip)$|linux.*(x86_64|amd64).*\.(zip|tar\.gz|deb)$)'
            PIN_ASSET='rustscan_@V@_amd64.deb' ;;
        ffuf)
            REPO="ffuf/ffuf"; BIN="ffuf"; PIN="${RETRO_PIN_FFUF:-2.1.0}"; TAG_PREFIX="v"
            ASSET_RES='linux_amd64\.tar\.gz$'
            PIN_ASSET='ffuf_@V@_linux_amd64.tar.gz' ;;
        httpx)
            REPO="projectdiscovery/httpx"; BIN="httpx"; PIN="${RETRO_PIN_HTTPX:-1.6.9}"; TAG_PREFIX="v"
            ASSET_RES='linux_amd64\.zip$'
            PIN_ASSET='httpx_@V@_linux_amd64.zip' ;;
        naabu)
            REPO="projectdiscovery/naabu"; BIN="naabu"; PIN="${RETRO_PIN_NAABU:-2.3.1}"; TAG_PREFIX="v"
            ASSET_RES='linux_amd64\.zip$'
            PIN_ASSET='naabu_@V@_linux_amd64.zip' ;;
        *) return 1 ;;
    esac
}

curl_dl() {
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 "$@"
}

gh_release_json() {
    local repo="$1" tag="$2" out="$3" url
    if [[ "${tag}" == "latest" ]]; then
        url="https://api.github.com/repos/${repo}/releases/latest"
    else
        url="https://api.github.com/repos/${repo}/releases/tags/${tag}"
    fi
    local -a hdr=(-H "Accept: application/vnd.github+json" -H "User-Agent: retro-os-fetch-tools")
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        hdr+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
    curl_dl "${hdr[@]}" -o "${out}" "${url}"
}

# json -> "tag" on line 1, then "name<TAB>url" per asset
parse_release() {
    python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("tag_name", ""))
for a in d.get("assets", []):
    print("%s\t%s" % (a["name"], a["browser_download_url"]))
PY
}

pick_asset() {   # listing(file) -> prints "name<TAB>url" of first regex hit
    local listing="$1" re hit
    while IFS= read -r re; do
        [[ -n "${re}" ]] || continue
        hit="$(tail -n +2 "${listing}" | awk -F'\t' -v re="${re}" '$1 ~ re {print; exit}')"
        if [[ -n "${hit}" ]]; then printf '%s\n' "${hit}"; return 0; fi
    done <<< "${ASSET_RES}"
    return 1
}

verify_signed_tag() {
    local repo="${1}" tag="${2}" work ref_json tag_json commit_json ref_type sha rc
    local -a hdr
    work="$(mktemp -d)"
    ref_json="${work}/ref.json"
    tag_json="${work}/tag.json"
    commit_json="${work}/commit.json"
    hdr=(-H "Accept: application/vnd.github+json" -H "User-Agent: retro-os-fetch-tools")
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then hdr+=(-H "Authorization: Bearer ${GITHUB_TOKEN}"); fi
    if ! curl_dl "${hdr[@]}" -o "${ref_json}" "https://api.github.com/repos/${repo}/git/ref/tags/${tag}"; then
        rm -rf "${work}"; return 1
    fi
    read -r ref_type sha < <(python3 - "${ref_json}" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print(d.get("object", {}).get("type", ""), d.get("object", {}).get("sha", ""))
PY
)
    if [[ "${ref_type}" == "tag" && -n "${sha}" ]]; then
        if ! curl_dl "${hdr[@]}" -o "${tag_json}" "https://api.github.com/repos/${repo}/git/tags/${sha}"; then
            rm -rf "${work}"; return 1
        fi
        read -r ref_type sha < <(python3 - "${tag_json}" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print(d.get("object", {}).get("type", ""), d.get("object", {}).get("sha", ""))
PY
)
    fi
    if [[ "${ref_type}" != "commit" || -z "${sha}" ]] ||
       ! curl_dl "${hdr[@]}" -o "${commit_json}" "https://api.github.com/repos/${repo}/commits/${sha}"; then
        rm -rf "${work}"; return 1
    fi
    python3 - "${commit_json}" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
raise SystemExit(0 if d.get("commit", {}).get("verification", {}).get("verified") is True else 1)
PY
    rc=$?
    rm -rf "${work}"
    return "${rc}"
}

verify_checksum() {   # file asset listing repo tag -> verified | verified-attested | verified-tag-signature | unverified | MISMATCH
    local file="${1}" asset="${2}" listing="${3}" repo="${4}" tag="${5}"
    local sums_url sums want got gh_version attested=0
    if command -v gh >/dev/null 2>&1; then
        gh_version="$(gh version 2>/dev/null | awk 'NR == 1 {print $3}')"
        if [[ -n "${gh_version}" ]] && dpkg --compare-versions "${gh_version}" ge 2.67.0 &&
           gh attestation verify "${file}" --repo "${repo}" >/dev/null 2>&1; then
            attested=1
        fi
    fi
    sums_url="$(tail -n +2 "${listing}" | awk -F'\t' '
        tolower($1) ~ /(sha256sums?([.]txt)?|checksums?([.]txt)?|[.]sha256(sum)?([.]txt)?)$/ {
            print $2; exit
        }')"
    if [[ -n "${sums_url}" ]]; then
        sums="$(curl_dl "${sums_url}" 2>/dev/null)" || sums=""
        if [[ -n "${sums}" ]]; then
            want="$(printf '%s\n' "${sums}" | python3 -c '
import os,re,sys
asset=os.path.basename(sys.argv[1])
for line in sys.stdin:
 m=re.match(r"^\s*([0-9a-fA-F]{64})\s+[* ]?(.+?)\s*$",line)
 if m and os.path.basename(m.group(2))==asset:
  print(m.group(1).lower()); break
 m=re.match(r"^\s*SHA256\s*\((.+?)\)\s*=\s*([0-9a-fA-F]{64})\s*$",line,re.I)
 if m and os.path.basename(m.group(1))==asset:
  print(m.group(2).lower()); break
' "${asset}")"
            if [[ -n "${want}" ]]; then
                got="$(sha256sum "${file}" | awk '{print $1}')"
                if [[ "${want}" != "${got}" ]]; then echo "MISMATCH"; return 0; fi
                if (( attested )); then echo "verified-attested"; else echo "verified"; fi
                return 0
            fi
        fi
    fi
    if (( attested )); then echo "verified-attested"; return 0; fi
    # RustScan publishes no checksum manifest or artifact attestation.
    # Require GitHub's API to report its release tag commit signature as valid.
    if [[ "${repo}" == "bee-san/RustScan" ]] && verify_signed_tag "${repo}" "${tag}"; then
        echo "verified-tag-signature"
    else
        echo "unverified"
    fi
}

is_elf() {
    [[ "$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]]
}

extract_archive() {   # file outdir
    local file="$1" out="$2" inner
    mkdir -p "${out}"
    case "${file}" in
        *.deb)            dpkg-deb -x "${file}" "${out}" ;;
        *.tar.gz|*.tgz)   tar -xzf "${file}" -C "${out}" ;;
        *.zip)
            unzip -q -o "${file}" -d "${out}"
            # some projects ship a zip that wraps a tar.gz
            while IFS= read -r inner; do
                tar -xzf "${inner}" -C "${out}" || true
            done < <(find "${out}" -type f \( -name '*.tar.gz' -o -name '*.tgz' \))
            ;;
        *)                cp "${file}" "${out}/" ;;
    esac
}

record_manifest() {   # name tag asset sha status
    local name="$1"
    mkdir -p "$(dirname "${MANIFEST}")"
    touch "${MANIFEST}"
    grep -v "^${name}|" "${MANIFEST}" > "${MANIFEST}.tmp" || true
    printf '%s|%s|%s|%s|%s|%s\n' "$@" "$(date -u +%FT%TZ)" >> "${MANIFEST}.tmp"
    mv -f "${MANIFEST}.tmp" "${MANIFEST}"
    chmod 0644 "${MANIFEST}"
}

stage_tool() {
    local name="$1" work json listing tag="" used="" asset_name="" asset_url="" hit status bin_path sha
    tool_meta "${name}" || { warn "unknown tool: ${name}"; return 2; }

    work="$(mktemp -d)"
    json="${work}/release.json"
    listing="${work}/assets.tsv"
    : > "${listing}"

    if [[ "${CHANNEL}" == "latest" ]] && gh_release_json "${REPO}" latest "${json}" 2>/dev/null; then
        used="latest"
    elif gh_release_json "${REPO}" "${TAG_PREFIX}${PIN}" "${json}" 2>/dev/null; then
        used="pinned"
    fi

    if [[ -n "${used}" ]]; then
        parse_release "${json}" > "${listing}" || true
        tag="$(head -n1 "${listing}")"
        if hit="$(pick_asset "${listing}")"; then
            asset_name="${hit%%$'\t'*}"
            asset_url="${hit#*$'\t'}"
        else
            warn "${name}: no matching asset in ${used} release ${tag}"
        fi
    fi

    if [[ -z "${asset_url}" ]]; then
        asset_name="${PIN_ASSET//@V@/${PIN}}"
        tag="${TAG_PREFIX}${PIN}"
        asset_url="https://github.com/${REPO}/releases/download/${tag}/${asset_name}"
        used="pinned-direct"
        warn "${name}: falling back to direct pinned URL"
        # Load the pinned release's own asset/checksum listing.
        if gh_release_json "${REPO}" "${tag}" "${json}" 2>/dev/null; then
            parse_release "${json}" > "${listing}" || true
            pinned_tag="$(head -n1 "${listing}")"
            [[ -n "${pinned_tag}" ]] && tag="${pinned_tag}"
        else
            : > "${listing}"
        fi
    fi

    log "${name}: ${tag} (${used}) <- ${asset_name}"
    if ! curl_dl -o "${work}/${asset_name}" "${asset_url}"; then
        warn "${name}: download failed (${asset_url})"
        rm -rf "${work}"; return 1
    fi

    status="$(verify_checksum "${work}/${asset_name}" "${asset_name}" "${listing}" "${REPO}" "${tag}")"
    case "${status}" in
        verified|verified-attested|verified-tag-signature)
            ;;
        MISMATCH)
            warn "${name}: SHA-256 MISMATCH; refusing this release as potentially compromised"
            rm -rf "${work}"; return 2
            ;;
        *)
            warn "${name}: integrity could not be authenticated (${status}); skipping this optional binary"
            rm -rf "${work}"; return 1
            ;;
    esac

    extract_archive "${work}/${asset_name}" "${work}/x"
    bin_path="$(find "${work}/x" -type f -name "${BIN}" | head -n1)"
    if [[ -z "${bin_path}" ]] && is_elf "${work}/x/${asset_name}" 2>/dev/null; then
        bin_path="${work}/x/${asset_name}"
    fi
    if [[ -z "${bin_path}" ]] || ! is_elf "${bin_path}"; then
        warn "${name}: no ELF binary named '${BIN}' found in ${asset_name}"
        rm -rf "${work}"; return 1
    fi

    install -D -m 0755 -o root -g root "${bin_path}" "${DEST}/.${BIN}.new"
    mv -f "${DEST}/.${BIN}.new" "${DEST}/${BIN}"
    sha="$(sha256sum "${DEST}/${BIN}" | awk '{print $1}')"
    record_manifest "${name}" "${tag}" "${asset_name}" "${sha}" "${status}"
    log "${name}: installed ${DEST}/${BIN} (checksum: ${status})"
    rm -rf "${work}"
}

main() {
    local -a wanted=()
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --all)    wanted=("${ALL_TOOLS[@]}") ;;
            --strict) STRICT=1 ;;
            --list)
                [[ -r "${MANIFEST}" ]] && cat "${MANIFEST}" || echo "no tools staged yet"
                exit 0 ;;
            -h|--help)
                echo "usage: retro-fetch-tools {--all | rustscan ffuf httpx naabu} [--strict] | --list"
                exit 0 ;;
            *) wanted+=("${arg}") ;;
        esac
    done
    [[ ${#wanted[@]} -gt 0 ]] || wanted=("${ALL_TOOLS[@]}")

    local t failed=0 rc
    for t in "${wanted[@]}"; do
        if stage_tool "${t}"; then
            :
        else
            rc=$?
            failed=$(( failed + 1 ))
            record_manifest "${t}" "-" "-" "-" "SKIPPED"
            # A proven hash mismatch is a security failure, not an optional-tool
            # availability issue. Never continue after detecting one.
            if (( rc == 2 )); then
                warn "${t}: security verification failed; stopping tool staging"
                exit 1
            fi
        fi
    done

    if (( failed > 0 )); then
        warn "${failed} requested tool(s) were unavailable or could not be authenticated"
        if (( STRICT == 1 )); then exit 1; fi
    fi
    exit 0
}

main "$@"
EOF
}

stage_modern_tools() {
    retro_info "Staging required upstream RustScan, ProjectDiscovery httpx and Naabu binaries"
    if ! "${RETRO_HELPER_DIR}/retro-fetch-tools" rustscan httpx naabu --strict; then
        retro_die "Required RustScan/httpx/Naabu binaries could not be authenticated and installed"
    fi
    if ! command -v ffuf >/dev/null 2>&1; then
        retro_info "ffuf is not available from APT; installing the official ffuf Linux amd64 release"
        "${RETRO_HELPER_DIR}/retro-fetch-tools" ffuf --strict \
            || retro_die "ffuf is missing and the official upstream binary could not be verified"
    else
        retro_ok "ffuf provided by the Debian APT package"
    fi
    cat "${RETRO_ETC_DIR}/modern-tools.manifest" 2>/dev/null || true
}
# -----------------------------------------------------------------------------
# 3. Retro AI daemon
# -----------------------------------------------------------------------------
install_retro_ai() {
    retro_info "Installing Retro AI daemon service"
    [[ -s "${RETRO_AI_DIR}/retro_ai.py" ]] \
        || retro_die "${RETRO_AI_DIR}/retro_ai.py is missing - the overlay payload was not applied (check overlay/opt/retro-ai/)"
    chmod 0755 "${RETRO_AI_DIR}/retro_ai.py"
    python3 -m py_compile "${RETRO_AI_DIR}/retro_ai.py" \
        || retro_die "retro_ai.py has a Python syntax error"
    find "${RETRO_AI_DIR}" -name '__pycache__' -type d -prune -exec rm -rf {} +

    retro_write "${RETRO_ETC_DIR}/retro-ai.conf" 0644 <<'EOF'
[watch]
# seconds between samples
interval = 30
# alert when used RAM (MemTotal-MemAvailable) reaches these percentages
ram_warn = 85
ram_crit = 92
# alert when free space on / drops below these percentages
disk_warn_free = 10
disk_crit_free = 5
# repeat an unchanged alert at most every N seconds
cooldown = 300
# speak alerts with espeak-ng (needs a sound card)
voice = true
voice_speed = 150
EOF

    retro_write /etc/systemd/system/retro-ai-watchdog.service 0644 <<'EOF'
[Unit]
Description=Retro AI watchdog (RAM / disk monitor with optional voice alerts)
After=multi-user.target retro-hwprofile.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/retro-ai/retro_ai.py watch
Restart=on-failure
RestartSec=10
Nice=10
CPUQuota=10%
MemoryMax=48M
RuntimeDirectory=retro-ai
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable retro-ai-watchdog.service
}

# -----------------------------------------------------------------------------
# 4. Boot health reporter (consumed by test_iso.sh via the serial console)
# -----------------------------------------------------------------------------
install_boot_report() {
    retro_info "Installing retro-boot-report (enabled with kernel arg retro.report=1)"
    retro_write "${RETRO_HELPER_DIR}/retro-boot-report" 0755 <<'EOF'
#!/usr/bin/env bash
# retro-boot-report - prints machine-parsable health markers to the console.
# Lines look like:  RETRO_TEST: KEY=value     (consumed by test_iso.sh)
set -u
mark() { printf 'RETRO_TEST: %s=%s\n' "$1" "$2"; }
yn()   { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }

echo "RETRO_REPORT_BEGIN"
mark KERNEL "$(uname -r)"
mark SYSTEM_STATE "$(systemctl is-system-running 2>/dev/null || true)"
# shellcheck source=/dev/null
[[ -r /run/retro-os/profile.env ]] && . /run/retro-os/profile.env
mark TIER "${RETRO_TIER:-unknown}"
mark RAM_MB "${RETRO_RAM_MB:-unknown}"
mark ZRAM "$(swapon --noheadings --show=NAME 2>/dev/null | grep -c '^/dev/zram' || true)"
mark SWAPPINESS "$(cat /proc/sys/vm/swappiness 2>/dev/null)"
mark EARLYOOM_ARGS "$(sed -n 's/^EARLYOOM_ARGS=//p' /etc/default/earlyoom 2>/dev/null | tr -d '"' | cut -d' ' -f1-4)"
mark EARLYOOM_ACTIVE "$(systemctl is-active earlyoom 2>/dev/null || true)"
mark BBR "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"

failed="$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l)"
mark FAILED_UNITS "${failed}"
if (( failed > 0 )); then systemctl --failed --no-legend --plain 2>/dev/null | sed 's/^/RETRO_DETAIL: failed-unit /'; fi

mark LIGHTDM_ACTIVE "$(systemctl is-active lightdm 2>/dev/null || true)"
mark NETWORKMANAGER_ACTIVE "$(systemctl is-active NetworkManager 2>/dev/null || true)"
mark BLUETOOTH_ACTIVE "$(systemctl is-active bluetooth 2>/dev/null || true)"
mark HWPROFILE_ACTIVE "$(systemctl is-active retro-hwprofile 2>/dev/null || true)"
retro_uid="$(id -u retro 2>/dev/null || true)"
if [[ -n "${retro_uid}" ]]; then
    mark OPENBOX_RUNNING "$(yn pgrep -u "${retro_uid}" -x openbox)"
    mark TINT2_RUNNING "$(yn pgrep -u "${retro_uid}" -x tint2)"
    mark PROC_pcmanfm "$(yn pgrep -u "${retro_uid}" -f 'pcmanfm --desktop')"
    for p in nm-applet blueman-applet volumeicon; do
        mark "PROC_${p//-/_}" "$(yn pgrep -u "${retro_uid}" -x "${p}")"
    done
else
    mark OPENBOX_RUNNING no
    mark TINT2_RUNNING no
    mark PROC_pcmanfm no
    mark PROC_nm_applet no
    mark PROC_blueman_applet no
    mark PROC_volumeicon no
fi
mark JGMENU_INSTALLED "$(yn command -v jgmenu_run)"
mark LXTERMINAL_INSTALLED "$(yn command -v lxterminal)"
mark XORG_RUNNING "$(yn pgrep -x Xorg)"
if [[ -S /tmp/.X11-unix/X0 ]]; then mark X11_SOCKET yes; else mark X11_SOCKET no; fi
openbox_pid="$(pgrep -u "${retro_uid:-0}" -x openbox 2>/dev/null | head -n1 || true)"
display_value=""
if [[ -n "${openbox_pid}" && -r "/proc/${openbox_pid}/environ" ]]; then
    display_value="$(tr '\0' '\n' < "/proc/${openbox_pid}/environ" | sed -n 's/^DISPLAY=//p' | head -n1 || true)"
fi
mark DISPLAY "${display_value:-none}"
loop=0
for f in /var/log/lightdm/lightdm.log; do
    [[ -r "${f}" ]] || continue
    n="$(grep -ciE '(session|greeter).*(exited|failed|terminated)' "${f}" 2>/dev/null || true)"
    if [[ "${n:-0}" -gt 0 ]]; then
        loop=1
        grep -iE '(session|greeter).*(exited|failed|terminated)' "${f}" | tail -n 5 | sed 's/^/RETRO_DETAIL: lightdm /'
    fi
done
mark LOGIN_LOOP_SUSPECT "${loop}"

xlog=""
for f in /var/log/Xorg.0.log "/home/retro/.local/share/xorg/Xorg.0.log"; do
    [[ -r "${f}" ]] && { xlog="${f}"; break; }
done
if [[ -n "${xlog}" ]]; then
    ee="$(grep -c '(EE)' "${xlog}" 2>/dev/null || true)"
    mark XORG_ERRORS "${ee:-0}"
    grep '(EE)' "${xlog}" 2>/dev/null | grep -v 'Failed to load module' | head -n 8 | sed 's/^/RETRO_DETAIL: xorg /'
else
    mark XORG_ERRORS "no-log"
fi

mark WALLPAPER "$([[ -s /usr/share/backgrounds/retro-os/wallpaper.png ]] && echo yes || echo no)"
mark RETRO_CLI "$(yn retro --version)"

for t in nmap tshark aircrack-ng hydra john nikto sqlmap wifite rustscan ffuf httpx naabu; do
    if command -v "${t}" >/dev/null 2>&1; then
        timeout 20 "${t}" --help >/dev/null 2>&1 < /dev/null
        rc=$?
        if (( rc == 124 || rc == 126 || rc == 127 )); then mark "TOOL_${t//-/_}" "noexec(${rc})"; else mark "TOOL_${t//-/_}" "ok"; fi
    else
        mark "TOOL_${t//-/_}" "missing"
    fi
done

journalctl -b -p err --no-pager -q 2>/dev/null | tail -n 15 | sed 's/^/RETRO_DETAIL: journal-err /'
echo "RETRO_REPORT_DONE"
EOF

    retro_write /etc/systemd/system/retro-boot-report.service 0644 <<'EOF'
[Unit]
Description=Retro OS boot health report (debug/test only: kernel arg retro.report=1)
After=graphical.target display-manager.service retro-ai-watchdog.service
ConditionKernelCommandLine=retro.report=1

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 25
ExecStart=/opt/retro-os/bin/retro-boot-report
StandardOutput=journal+console
TimeoutStartSec=240

[Install]
WantedBy=graphical.target
EOF
    systemctl enable retro-boot-report.service
}

# -----------------------------------------------------------------------------
# 5. Overlay payload sanity + menus
# -----------------------------------------------------------------------------
verify_overlay_payload() {
    retro_info "Verifying overlay payload"
    [[ -s "${RETRO_BIN_DIR}/retro" ]] \
        || retro_die "${RETRO_BIN_DIR}/retro missing - overlay/usr/local/bin/retro was not applied"
    chmod 0755 "${RETRO_BIN_DIR}/retro"
    bash -n "${RETRO_BIN_DIR}/retro" || retro_die "retro CLI has a bash syntax error"
}

regenerate_menus() {
    retro_info "Regenerating menus now that all tools are installed"
    "${RETRO_HELPER_DIR}/retro-menu-gen" --system
    "${RETRO_HELPER_DIR}/retro-menu-gen" --list || true
}

main() {
    retro_info "=== 03_modules_setup.sh: start ==="
    install_classic_tools
    write_fetcher
    stage_modern_tools
    install_retro_ai
    install_boot_report
    verify_overlay_payload
    regenerate_menus
    retro_ok "=== 03_modules_setup.sh: complete ==="
}

main "$@"
