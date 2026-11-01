#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 - 02_interface_setup.sh   (runs as root INSIDE the build chroot)
#
#   * Xorg + Openbox + Tint2 + PCManFM + Picom + Xfce4-Terminal + jgmenu
#   * LightDM auto-login with explicit PAM stack (no black-screen login loop)
#   * Windows 7-inspired theming (bottom panel, start orb, glass menu)
#   * /etc/skel session files, helper scripts, dynamic menu generator
#   * Multimedia apps (VLC, Evince, etc.)
# =============================================================================
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SELF_DIR}/config.env"
retro_enable_traps "02_interface_setup.sh"
retro_require_chroot

export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C

SKEL="/etc/skel"
TEMPLATE_DIR="${RETRO_ROOT}/templates"
WALLPAPER="/usr/share/backgrounds/retro-os/wallpaper.png"

# -----------------------------------------------------------------------------
# 1. Packages
# -----------------------------------------------------------------------------
install_graphical_stack() {
    retro_info "Preseeding default display manager = lightdm"
    echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections
    echo "libpam-runtime libpam-runtime/override boolean false" | debconf-set-selections || true

    retro_info "Installing Xorg, drivers and session components"
    retro_apt_install \
        xserver-xorg-core xserver-xorg-legacy xserver-xorg-input-libinput \
        xserver-xorg-video-fbdev xserver-xorg-video-vesa \
        libgl1-mesa-dri libglx-mesa0 \
        xinit xauth x11-xserver-utils x11-utils x11-xkb-utils \
        xdg-utils xdg-user-dirs dbus-x11 \
        lightdm lightdm-gtk-greeter \
        openbox obconf tint2 pcmanfm feh picom jgmenu xfce4-terminal \
        mousepad lxtask lxappearance scrot dmenu \
        network-manager-gnome volumeicon-alsa \
        policykit-1 policykit-1-gnome udisks2 \
        arc-theme papirus-icon-theme adwaita-icon-theme gtk2-engines-murrine \
        librsvg2-common fonts-dejavu-core fonts-jetbrains-mono \
        gvfs gvfs-backends gvfs-daemons gvfs-fuse libmtp-runtime jmtpfs usbmount \
        cbatticon parcellite pavucontrol blueman \
        badwolf geany geany-plugins \
        vlc ristretto evince galculator xarchiver p7zip-full unrar-free

    retro_apt_install_optional \
        xserver-xorg-video-vmware xserver-xorg-video-qxl \
        xserver-xorg-video-nouveau xserver-xorg-video-ati xserver-xorg-video-amdgpu

    if [[ "${RETRO_INSTALL_BROWSER}" == "1" ]]; then
        retro_apt_install_optional firefox-esr
    fi
}

# -----------------------------------------------------------------------------
# 2. Branding assets
# -----------------------------------------------------------------------------
install_branding_assets() {
    retro_info "Installing branding assets"
    mkdir -p /usr/share/backgrounds/retro-os /usr/share/pixmaps

    if [[ ! -s /usr/share/pixmaps/retro-start.svg ]]; then
        retro_write /usr/share/pixmaps/retro-start.svg 0644 <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
  <defs>
    <radialGradient id="g" cx="35%" cy="30%" r="75%">
      <stop offset="0" stop-color="#7dffd0"/>
      <stop offset="0.55" stop-color="#00ff9c"/>
      <stop offset="1" stop-color="#007a4c"/>
    </radialGradient>
    <linearGradient id="r" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
  </defs>
  <circle cx="32" cy="32" r="29" fill="#0c0d12" stroke="#00ff9c" stroke-width="2"/>
  <circle cx="32" cy="32" r="24" fill="url(#g)"/>
  <ellipse cx="32" cy="20" rx="17" ry="9" fill="url(#r)"/>
  <path d="M23 43V21h10a7 7 0 0 1 0 14h-4l8 8" fill="none" stroke="#0c0d12"
        stroke-width="4.5" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
EOF
    fi

    retro_write /usr/share/applications/retro-start.desktop 0644 <<'EOF'
[Desktop Entry]
Type=Application
Name=Start
Comment=Retro OS Start Menu
Exec=jgmenu_run
Icon=/usr/share/pixmaps/retro-start.svg
Terminal=false
NoDisplay=true
Categories=Utility;
EOF
}

# -----------------------------------------------------------------------------
# 3. Templates + helper scripts
# -----------------------------------------------------------------------------
write_templates() {
    retro_info "Writing LightDM / PAM templates"
    mkdir -p "${TEMPLATE_DIR}" "${RETRO_HELPER_DIR}" "${RETRO_ROOT}/menu.d"

    retro_write "${TEMPLATE_DIR}/lightdm.conf" 0644 <<EOF
[LightDM]
minimum-vt=7

[Seat:*]
autologin-user=${RETRO_USER}
autologin-user-timeout=0
autologin-session=openbox
user-session=openbox
greeter-session=lightdm-gtk-greeter
allow-guest=false
greeter-hide-users=false
session-wrapper=/etc/X11/Xsession
xserver-command=X -nolisten tcp
EOF

    retro_write "${TEMPLATE_DIR}/lightdm-autologin.pam" 0644 <<'EOF'
#%PAM-1.0
auth      requisite pam_nologin.so
auth      required  pam_succeed_if.so user != root quiet_success
auth      required  pam_succeed_if.so user ingroup nopasswdlogin
auth      required  pam_permit.so
@include common-account
session   required  pam_limits.so
session   required  pam_env.so readenv=1
session   required  pam_env.so readenv=1 envfile=/etc/default/locale
@include common-session
EOF

    retro_write "${TEMPLATE_DIR}/lightdm-gtk-greeter.conf" 0644 <<EOF
[greeter]
background=${WALLPAPER}
theme-name=${RETRO_GTK_THEME}
icon-theme-name=${RETRO_ICON_THEME}
font-name=${RETRO_UI_FONT} 11
position=50%,center
EOF

    retro_write "${TEMPLATE_DIR}/Xwrapper.config" 0644 <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF
}

install_login_stack() {
    retro_info "Installing LightDM auto-login configuration + PAM bypass"
    mkdir -p /etc/lightdm/lightdm.conf.d /etc/X11
    install -m 0644 "${TEMPLATE_DIR}/lightdm.conf"            /etc/lightdm/lightdm.conf
    install -m 0644 "${TEMPLATE_DIR}/lightdm.conf"            /etc/lightdm/lightdm.conf.d/50-retro-autologin.conf
    install -m 0644 "${TEMPLATE_DIR}/lightdm-gtk-greeter.conf" /etc/lightdm/lightdm-gtk-greeter.conf
    install -m 0644 "${TEMPLATE_DIR}/lightdm-autologin.pam"   /etc/pam.d/lightdm-autologin
    install -m 0644 "${TEMPLATE_DIR}/Xwrapper.config"         /etc/X11/Xwrapper.config

    echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
    systemctl enable lightdm.service
    systemctl set-default graphical.target
}

# -----------------------------------------------------------------------------
# 4. Helper scripts
# -----------------------------------------------------------------------------
write_session_start() {
    retro_write "${RETRO_HELPER_DIR}/retro-session-start" 0755 <<'EOF'
#!/usr/bin/env bash
set -u

PROFILE_ENV="/run/retro-os/profile.env"
[[ -r "${PROFILE_ENV}" ]] && . "${PROFILE_ENV}"
RETRO_TIER="${RETRO_TIER:-standard}"
RETRO_PICOM="${RETRO_PICOM:-on}"

CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}"
mkdir -p "${CACHE_DIR}" "${HOME}/.config/retro"
exec >>"${CACHE_DIR}/retro-session.log" 2>&1
echo "=== retro-session-start $(date '+%F %T') tier=${RETRO_TIER} picom=${RETRO_PICOM} ==="

running() { pgrep -u "$(id -u)" -x "$1" >/dev/null 2>&1; }

start_once() {
    local name="$1"; shift
    if running "${name}"; then return 0; fi
    command -v "$1" >/dev/null 2>&1 || [[ -x "$1" ]] || { echo "skip ${name}: $1 not found"; return 0; }
    "$@" &
}

want_picom="${RETRO_PICOM}"
if [[ -r "${HOME}/.config/retro/compositor" ]]; then
    case "$(head -n1 "${HOME}/.config/retro/compositor" | tr -d '[:space:]')" in
        on)  want_picom="on" ;;
        off) want_picom="off" ;;
    esac
fi

xsetroot -solid '#0c0d12' 2>/dev/null || true
xset b off 2>/dev/null || true

start_once polkit-gnome-au /usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1

if command -v pcmanfm >/dev/null 2>&1; then
    start_once pcmanfm pcmanfm --desktop
elif command -v feh >/dev/null 2>&1; then
    feh --bg-scale /usr/share/backgrounds/retro-os/wallpaper.png &
fi
sleep 1

panel_cfg="${HOME}/.config/tint2/tint2rc"
if [[ "${want_picom}" == "on" ]] && command -v picom >/dev/null 2>&1; then
    if ! running picom; then
        picom --config "${HOME}/.config/picom/picom.conf" -b || echo "picom failed to start"
        sleep 0.5
    fi
    if running picom; then
        panel_cfg="${HOME}/.config/tint2/tint2rc.glass"
    fi
fi
[[ -r "${panel_cfg}" ]] || panel_cfg="${HOME}/.config/tint2/tint2rc"
start_once tint2 tint2 -c "${panel_cfg}"
sleep 0.5

# ട്രേ ആപ്‌ലെറ്റുകൾ (Network, Volume, Bluetooth, Clipboard, Battery)
start_once nm-applet nm-applet
start_once volumeicon volumeicon
start_once blueman-applet blueman-applet
start_once parcellite parcellite
start_once cbatticon cbatticon -u 5

for ctl in Master Speaker Headphone PCM; do
    amixer -q sset "${ctl}" 80% unmute >/dev/null 2>&1 || true
done

if grep -qw 'retro.install=1' /proc/cmdline 2>/dev/null && command -v calamares >/dev/null 2>&1; then
    sudo -E calamares &
fi

wait
EOF
}

write_live_fixup() {
    retro_write "${RETRO_HELPER_DIR}/retro-live-fixup" 0750 <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

TPL="/opt/retro-os/templates"
USER_NAME="retro"
USER_UID="1000"
TAG="retro-live-fixup"
log() { logger -t "${TAG}" -- "$*" 2>/dev/null || true; echo "[${TAG}] $*"; }

for g in autologin nopasswdlogin wireshark; do
    getent group "${g}" >/dev/null || { groupadd --system "${g}"; log "created group ${g}"; }
done

if ! id -u "${USER_NAME}" >/dev/null 2>&1; then
    log "user ${USER_NAME} missing - recreating"
    useradd --create-home --uid "${USER_UID}" --user-group --shell /bin/bash \
        --comment "Retro OS User" "${USER_NAME}" 2>/dev/null \
        || useradd --create-home --user-group --shell /bin/bash "${USER_NAME}"
    cp -a /etc/skel/. "/home/${USER_NAME}/" 2>/dev/null || true
fi

for g in autologin nopasswdlogin sudo audio video plugdev netdev wireshark; do
    getent group "${g}" >/dev/null && usermod -aG "${g}" "${USER_NAME}" || true
done
usermod --shell /bin/bash "${USER_NAME}" || true

status="$(passwd -S "${USER_NAME}" 2>/dev/null | awk '{print $2}')"
if [[ "${status}" != "P" ]]; then
    log "password state '${status}' - resetting to default and unlocking"
    echo "${USER_NAME}:retro" | chpasswd
fi
usermod --unlock "${USER_NAME}" 2>/dev/null || true

sync_file() {
    local src="$1" dst="$2" mode="$3"
    [[ -r "${src}" ]] || return 0
    if ! cmp -s "${src}" "${dst}" 2>/dev/null; then
        mkdir -p "$(dirname "${dst}")"
        install -m "${mode}" "${src}" "${dst}"
        log "restored ${dst}"
    fi
}
sync_file "${TPL}/lightdm.conf"            /etc/lightdm/lightdm.conf                       0644
sync_file "${TPL}/lightdm.conf"            /etc/lightdm/lightdm.conf.d/50-retro-autologin.conf 0644
sync_file "${TPL}/lightdm-autologin.pam"   /etc/pam.d/lightdm-autologin                    0644
sync_file "${TPL}/Xwrapper.config"         /etc/X11/Xwrapper.config                        0644

home="/home/${USER_NAME}"
if [[ -d "${home}" ]]; then
    if [[ "$(stat -c %U:%G "${home}")" != "${USER_NAME}:${USER_NAME}" ]]; then
        chown -R "${USER_NAME}:${USER_NAME}" "${home}"
        log "fixed ownership of ${home}"
    fi
    rm -f "${home}/.Xauthority" "${home}/.ICEauthority"
    for f in .xsession .xinitrc; do
        [[ -e "${home}/${f}" ]] || { cp -a "/etc/skel/${f}" "${home}/${f}" 2>/dev/null && chown "${USER_NAME}:${USER_NAME}" "${home}/${f}"; }
    done
fi

chmod 1777 /tmp /var/tmp 2>/dev/null || true
mkdir -p /var/lib/lightdm /var/cache/lightdm /var/log/lightdm
chown lightdm:lightdm /var/lib/lightdm /var/cache/lightdm 2>/dev/null || true
log "login stack verified"
EOF

    retro_write /etc/systemd/system/retro-live-fixup.service 0644 <<'EOF'
[Unit]
Description=Retro OS live session login-stack guard
After=live-config.service local-fs.target
Before=systemd-user-sessions.service display-manager.service lightdm.service
ConditionKernelCommandLine=boot=live

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/retro-os/bin/retro-live-fixup

[Install]
WantedBy=graphical.target multi-user.target
EOF
    systemctl enable retro-live-fixup.service
}

write_menu_tools() {
    retro_info "Installing menu generator + tool catalogue"

retro_write "${RETRO_ROOT}/menu.d/10-security.list" 0644 <<'EOF'
Reconnaissance|Nmap (CLI)|nmap|--help|utilities-terminal|CLI
Reconnaissance|Nmap GUI (NmapSI4)|nmapsi4||utilities-terminal|GUI
Reconnaissance|RustScan|rustscan|--help|utilities-terminal|CLI
Web Audit|SQLMap|sqlmap|--help|utilities-terminal|CLI
Web Audit|ffuf|ffuf|--help|utilities-terminal|CLI
Passwords|Hydra (CLI)|hydra|--help|utilities-terminal|CLI
Passwords|Hydra (GUI - XHydra)|xhydra||security-high|GUI
Passwords|John the Ripper (CLI)|john||utilities-terminal|CLI
Passwords|John the Ripper (GUI - Johnny)|johnny||security-high|GUI
Wireless|Aircrack-ng|aircrack-ng|--help|utilities-terminal|CLI
Wireless|Wifite|wifite||utilities-terminal|CLI
Sniffing|Wireshark (GUI)|wireshark||wireshark|GUI
Firewall|Gufw Firewall (GUI)|gufw||security-high|GUI
EOF

    retro_write "${RETRO_HELPER_DIR}/retro-jgmenu-csv" 0755 <<'EOF'
#!/usr/bin/env bash
f="${XDG_CONFIG_HOME:-${HOME}/.config}/jgmenu/retro-menu.csv"
if [[ -r "${f}" ]]; then
    exec cat "${f}"
fi
exec jgmenu_run apps
EOF

    retro_write "${RETRO_HELPER_DIR}/retro-menu-gen" 0755 <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

LIST_DIR="${RETRO_MENU_LIST_DIR:-/opt/retro-os/menu.d}"
ROOT="${RETRO_MENU_ROOT:-}"
MARK="retro-os:generated"

declare -a CAT_ORDER=()
declare -A CAT_ITEMS=()

die()  { echo "retro-menu-gen: $*" >&2; exit 1; }
warn() { echo "retro-menu-gen: $*" >&2; }

xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"
    printf '%s' "${s}"
}

have() {
    [[ -n "${RETRO_MENU_ASSUME_ALL:-}" ]] && return 0
    command -v "$1" >/dev/null 2>&1
}

load_entries() {
    local f line cat label bin args icon mtype
    shopt -s nullglob
    for f in "${LIST_DIR}"/*.list; do
        while IFS= read -r line || [[ -n "${line}" ]]; do
            [[ -z "${line//[[:space:]]/}" ]] && continue
            [[ "${line}" =~ ^[[:space:]]*# ]] && continue
            IFS='|' read -r cat label bin args icon mtype <<< "${line}"
            if [[ -z "${cat}" || -z "${label}" || -z "${bin}" ]]; then
                continue
            fi
            have "${bin}" || continue
            icon="${icon:-utilities-terminal}"
            mtype="${mtype:-CLI}"
            if [[ -z "${CAT_ITEMS[${cat}]+x}" ]]; then
                CAT_ORDER+=("${cat}")
                CAT_ITEMS["${cat}"]=""
            fi
            CAT_ITEMS["${cat}"]+="${label}|${bin}|${args}|${icon}|${mtype}"$'\n'
        done < "${f}"
    done
}

ob_item() {
    printf '  <item label="%s">\n    <action name="Execute">\n      <command>%s</command>\n    </action>\n  </item>\n' \
        "$(xml_escape "$1")" "$(xml_escape "$2")"
}

build_openbox_menu() {
    local cat label bin args icon mtype cid=0 cmd_exec
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!-- %s -->\n' "${MARK}"
    printf '<openbox_menu xmlns="http://openbox.org/3.4/menu">\n'
    printf '<menu id="root-menu" label="Retro OS">\n'
    
    ob_item "Terminal" "xfce4-terminal"
    ob_item "File Manager" "pcmanfm"
    have firefox-esr && ob_item "Web Browser" "firefox-esr"
    have mousepad && ob_item "Text Editor" "mousepad"
    have vlc && ob_item "VLC Media Player" "vlc"
    printf '  <separator/>\n'

    if (( ${#CAT_ORDER[@]} > 0 )); then
        printf '  <menu id="retro-security" label="Security Tools">\n'
        for cat in "${CAT_ORDER[@]}"; do
            cid=$(( cid + 1 ))
            printf '  <menu id="retro-sec-%s" label="%s">\n' "${cid}" "$(xml_escape "${cat}")"
            while IFS='|' read -r label bin args icon mtype; do
                [[ -n "${label}" ]] || continue
                if [[ "${mtype}" == "GUI" ]]; then
                    cmd_exec="${bin} ${args}"
                else
                    cmd_exec="xfce4-terminal -x bash -c '${bin} ${args}; exec bash -i'"
                fi
                ob_item "${label}" "${cmd_exec}"
            done <<< "${CAT_ITEMS[${cat}]}"
            printf '  </menu>\n'
        done
        printf '  </menu>\n'
    fi

    printf '  <menu id="retro-media" label="Applications">\n'
    have vlc && ob_item "VLC Media Player" "vlc"
    have evince && ob_item "PDF Document Viewer" "evince"
    have ristretto && ob_item "Image Viewer" "ristretto"
    have galculator && ob_item "Calculator" "galculator"
    have xarchiver && ob_item "Archive Manager" "xarchiver"
    printf '  </menu>\n'

    printf '  <menu id="retro-system" label="Retro System">\n'
    ob_item "Retro Boost (free RAM)" "xfce4-terminal -x bash -c 'retro boost; exec bash -i'"
    ob_item "Retro Doctor (repair)"  "xfce4-terminal -x bash -c 'retro doctor; exec bash -i'"
    ob_item "Retro Update"           "xfce4-terminal -x bash -c 'retro update; exec bash -i'"
    ob_item "Retro AI Companion"     "xfce4-terminal -e 'retro ai'"
    ob_item "System Monitor"         "xfce4-terminal -e 'retro mon'"
    ob_item "System Info"            "xfce4-terminal -x bash -c 'retro fetch; exec bash -i'"
    have lxtask && ob_item "Task Manager" "lxtask"
    printf '  </menu>\n'

    printf '  <menu id="retro-settings" label="Settings">\n'
    have nm-connection-editor && ob_item "Network Connections" "nm-connection-editor"
    have lxappearance && ob_item "Appearance" "lxappearance"
    have obconf && ob_item "Openbox Configuration" "obconf"
    printf '  <item label="Reload Openbox">\n    <action name="Reconfigure"/>\n  </item>\n'
    printf '  </menu>\n'

    printf '  <separator/>\n'
    have calamares && ob_item "Install Retro OS" "sudo -E calamares"
    ob_item "Lock Screen" "dm-tool lock"
    printf '  <menu id="retro-exit" label="Exit">\n'
    printf '  <item label="Log Out">\n    <action name="Exit"/>\n  </item>\n'
    ob_item "Reboot" "systemctl reboot"
    ob_item "Shut Down" "systemctl poweroff"
    printf '  </menu>\n'
    printf '</menu>\n</openbox_menu>\n'
}

build_jgmenu_csv() {
    local cat label bin args icon mtype cid=0 cmd_exec
    {
        echo "Terminal,xfce4-terminal,utilities-terminal"
        echo "File Manager,pcmanfm,system-file-manager"
        have firefox-esr && echo "Web Browser,firefox-esr,firefox-esr"
        have mousepad && echo "Text Editor,mousepad,accessories-text-editor"
        have vlc && echo "VLC Media Player,vlc,vlc"
        echo "^sep()"
        if (( ${#CAT_ORDER[@]} > 0 )); then
            echo "Security Tools,^checkout(retro-sec),security-high"
        fi
        echo "Applications,^checkout(retro-apps),applications-other"
        echo "Retro System,^checkout(retro-sys),preferences-system"
        echo "Settings,^checkout(retro-set),preferences-desktop"
        echo "^sep()"
        have calamares && echo "Install Retro OS,sudo -E calamares,system-software-install"
        echo "Exit,^checkout(retro-exit),system-shutdown"
        echo
        if (( ${#CAT_ORDER[@]} > 0 )); then
            echo "^tag(retro-sec)"
            for cat in "${CAT_ORDER[@]}"; do
                cid=$(( cid + 1 ))
                echo "${cat},^checkout(retro-sec-${cid}),folder"
            done
            echo
            cid=0
            for cat in "${CAT_ORDER[@]}"; do
                cid=$(( cid + 1 ))
                echo "^tag(retro-sec-${cid})"
                while IFS='|' read -r label bin args icon mtype; do
                    [[ -n "${label}" ]] || continue
                    if [[ "${mtype}" == "GUI" ]]; then
                        cmd_exec="${bin} ${args}"
                    else
                        cmd_exec="xfce4-terminal -x bash -c '${bin} ${args}; exec bash -i'"
                    fi
                    echo "${label},${cmd_exec},${icon}"
                done <<< "${CAT_ITEMS[${cat}]}"
                echo
            done
        fi
        echo "^tag(retro-apps)"
        have vlc && echo "VLC Media Player,vlc,vlc"
        have evince && echo "Document Viewer,evince,x-office-document"
        have ristretto && echo "Image Viewer,ristretto,image-x-generic"
        have galculator && echo "Calculator,galculator,accessories-calculator"
        have xarchiver && echo "Archive Manager,xarchiver,package-x-generic"
        echo
        echo "^tag(retro-sys)"
        echo "Retro Boost,xfce4-terminal -x bash -c 'retro boost; exec bash -i',utilities-system-monitor"
        echo "Retro Doctor,xfce4-terminal -x bash -c 'retro doctor; exec bash -i',system-run"
        echo "Retro Update,xfce4-terminal -x bash -c 'retro update; exec bash -i',system-software-update"
        echo "Retro AI,xfce4-terminal -e 'retro ai',face-smile"
        echo "System Monitor,xfce4-terminal -e 'retro mon',utilities-system-monitor"
        echo "System Info,xfce4-terminal -x bash -c 'retro fetch; exec bash -i',computer"
        echo
        echo "^tag(retro-set)"
        have nm-connection-editor && echo "Network Connections,nm-connection-editor,preferences-system-network"
        have lxappearance && echo "Appearance,lxappearance,preferences-desktop-theme"
        have obconf && echo "Openbox Configuration,obconf,preferences-system"
        echo
        echo "^tag(retro-exit)"
        echo "Log Out,openbox --exit,system-log-out"
        echo "Reboot,systemctl reboot,system-reboot"
        echo "Shut Down,systemctl poweroff,system-shutdown"
    }
}

atomic_write() {
    local dest="$1" tmp
    mkdir -p "$(dirname "${dest}")"
    tmp="$(mktemp "${dest}.XXXXXX")"
    cat > "${tmp}"
    chmod 0644 "${tmp}"
    mv -f "${tmp}" "${dest}"
}

write_menus_to() {
    local base="$1" mode="$2"
    local ob="${base}/.config/openbox/menu.xml"
    local csv="${base}/.config/jgmenu/retro-menu.csv"
    build_openbox_menu | atomic_write "${ob}"
    build_jgmenu_csv | atomic_write "${csv}"
}

main() {
    local action="${1:-}"
    case "${action}" in
        --system)
            load_entries
            write_menus_to "${ROOT}/etc/skel" skel
            ;;
        --user)
            local home="${2:-${HOME}}"
            load_entries
            write_menus_to "${home}" user
            if [[ "$(id -u)" -eq 0 ]]; then
                local owner
                owner="$(stat -c %U:%G "${home}")"
                chown -R "${owner}" "${home}/.config/openbox" "${home}/.config/jgmenu" 2>/dev/null || true
            fi
            ;;
        --list)
            load_entries
            ;;
        *)
            exit 2
            ;;
    esac
}

main "$@"
EOF
}

# -----------------------------------------------------------------------------
# 5. Skeleton: session entry points
# -----------------------------------------------------------------------------
write_skel_session() {
    retro_info "Populating ${SKEL} (.xsession, .xinitrc, Openbox)"
    for f in .xsession .xinitrc; do
        retro_write "${SKEL}/${f}" 0755 <<'EOF'
#!/bin/sh
exec openbox-session
EOF
    done

    mkdir -p "${SKEL}/.config/openbox"
    retro_write "${SKEL}/.config/openbox/autostart" 0755 <<EOF
${RETRO_HELPER_DIR}/retro-session-start &
EOF
    retro_write "${SKEL}/.config/openbox/environment" 0644 <<'EOF'
export XDG_CURRENT_DESKTOP=Openbox
export _JAVA_AWT_WM_NONREPARENTING=1
export MOZ_USE_XINPUT2=1
EOF

    [[ -r /etc/xdg/openbox/rc.xml ]] || retro_die "/etc/xdg/openbox/rc.xml missing"
    cp /etc/xdg/openbox/rc.xml "${SKEL}/.config/openbox/rc.xml"
    RC_PATH="${SKEL}/.config/openbox/rc.xml" RETRO_GTK_THEME="${RETRO_GTK_THEME}" python3 - <<'PY'
import os, re, sys

path = os.environ["RC_PATH"]
theme = os.environ["RETRO_GTK_THEME"]
src = open(path, encoding="utf-8").read()

src, n = re.subn(r"(<theme>\s*<name>)[^<]*(</name>)", r"\g<1>%s\g<2>" % theme, src, count=1)
if n != 1:
    sys.exit("rc.xml: <theme><name> block not found")

src = re.sub(r"(<desktops>\s*<number>)\d+(</number>)", r"\g<1>2\g<2>", src, count=1)

def kb(key, cmd):
    return ('    <keybind key="%s"><action name="Execute"><command>%s</command></action></keybind>\n'
            % (key, cmd.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")))

extra = "    <!-- Retro OS bindings -->\n"
extra += kb("W-e", "pcmanfm")
extra += kb("W-t", "xfce4-terminal")
extra += kb("C-A-t", "xfce4-terminal")
extra += kb("W-space", "jgmenu_run")
extra += kb("C-Escape", "jgmenu_run")
extra += kb("A-F2", "dmenu_run")
extra += kb("W-l", "dm-tool lock")
extra += kb("W-m", "xfce4-terminal -e 'retro mon'")
extra += kb("W-b", "xfce4-terminal --hold -e 'retro boost'")
extra += kb("C-A-Delete", "lxtask")
extra += kb("Print", "scrot -e 'mv $f $HOME/Pictures/'")
extra += kb("XF86AudioRaiseVolume", "amixer -q sset Master 5%+ unmute")
extra += kb("XF86AudioLowerVolume", "amixer -q sset Master 5%- unmute")
extra += kb("XF86AudioMute", "amixer -q sset Master toggle")
extra += '    <keybind key="W-d"><action name="ToggleShowDesktop"/></keybind>\n'

if src.count("</keyboard>") != 1:
    sys.exit("rc.xml: expected exactly one </keyboard>")
src = src.replace("</keyboard>", extra + "  </keyboard>", 1)
open(path, "w", encoding="utf-8").write(src)
PY
    chmod 0644 "${SKEL}/.config/openbox/rc.xml"
}

write_skel_tint2() {
    retro_info "Writing Tint2 panel (Windows 7 style)"
    mkdir -p "${SKEL}/.config/tint2"
    retro_write "${SKEL}/.config/tint2/tint2rc" 0644 <<EOF
rounded = 0
border_width = 1
border_sides = T
background_color = #0c0d12 100
border_color = #00ff9c 45

rounded = 3
border_width = 1
border_sides = TBLR
background_color = #1b1d27 100
border_color = #2b2f3d 100

rounded = 3
border_width = 1
border_sides = TBLR
background_color = #1f3d33 100
border_color = #00ff9c 90

rounded = 3
border_width = 1
border_sides = TBLR
background_color = #3a1220 100
border_color = #ff0055 100

rounded = 2
border_width = 1
border_sides = TBLR
background_color = #0c0d12 100
border_color = #00ff9c 60

rounded = 20
border_width = 0
background_color = #00ff9c 0
border_color = #00ff9c 0

panel_items = LTSC
panel_size = 100% 40
panel_margin = 0 0
panel_padding = 4 2 4
panel_background_id = 1
wm_menu = 1
panel_dock = 0
panel_position = bottom center horizontal
panel_layer = top
panel_monitor = all
primary_monitor_first = 0
autohide = 0
strut_policy = follow_size
panel_window_name = tint2
disable_transparency = 1
mouse_effects = 0

launcher_padding = 4 2 8
launcher_background_id = 0
launcher_icon_background_id = 6
launcher_icon_size = 34
launcher_icon_asb = 100 0 0
launcher_icon_theme = ${RETRO_ICON_THEME}
launcher_icon_theme_override = 0
startup_notifications = 1
launcher_tooltip = 1
launcher_item_app = /usr/share/applications/retro-start.desktop
launcher_item_app = /usr/share/applications/pcmanfm.desktop
launcher_item_app = /usr/share/applications/xfce4-terminal.desktop
launcher_item_app = /usr/share/applications/firefox-esr.desktop

taskbar_mode = single_desktop
taskbar_hide_if_empty = 0
taskbar_padding = 2 2 2
taskbar_background_id = 0
taskbar_active_background_id = 0
taskbar_name = 0
taskbar_hide_inactive_tasks = 0
taskbar_hide_different_monitor = 0
taskbar_hide_different_desktop = 0
taskbar_always_show_all_desktop_tasks = 0
taskbar_distribute_size = 1
taskbar_sort_order = none
task_align = left

task_text = 1
task_icon = 1
task_centered = 0
urgent_nb_of_blink = 100000
task_maximum_size = 200 36
task_padding = 8 4 8
task_tooltip = 1
task_thumbnail = 0
task_font = ${RETRO_UI_FONT} 9
task_font_color = #e0e0e0 100
task_icon_asb = 100 0 0
task_active_font_color = #ffffff 100
task_active_icon_asb = 100 0 0
task_urgent_font_color = #ffffff 100
task_urgent_icon_asb = 100 0 0
task_iconified_font_color = #9aa0a6 100
task_iconified_icon_asb = 70 0 0
task_background_id = 2
task_active_background_id = 3
task_urgent_background_id = 4
task_iconified_background_id = 2
mouse_left = toggle_iconify
mouse_middle = none
mouse_right = close
mouse_scroll_up = toggle
mouse_scroll_down = iconify

systray_padding = 4 2 3
systray_background_id = 0
systray_sort = ascending
systray_icon_size = 22
systray_icon_asb = 100 0 0
systray_monitor = 1
systray_name_filter =

time1_format = %H:%M
time1_font = ${RETRO_UI_FONT} Bold 10
time2_format = %d-%m-%Y
time2_font = ${RETRO_UI_FONT} 8
clock_font_color = #e0e0e0 100
clock_padding = 8 0
clock_background_id = 0
clock_tooltip = %A, %d %B %Y
clock_lclick_command =
clock_rclick_command =

tooltip_show_timeout = 0.5
tooltip_hide_timeout = 0.1
tooltip_padding = 6 4
tooltip_background_id = 5
tooltip_font_color = #e0e0e0 100
tooltip_font = ${RETRO_UI_FONT} 9
EOF

    sed -e 's/^disable_transparency = 1/disable_transparency = 0/' \
        -e 's/^background_color = #0c0d12 100/background_color = #0c0d12 82/' \
        "${SKEL}/.config/tint2/tint2rc" > "${SKEL}/.config/tint2/tint2rc.glass"
    chmod 0644 "${SKEL}/.config/tint2/tint2rc.glass"
}

write_skel_jgmenu_picom_pcmanfm() {
    retro_info "Writing jgmenu, Picom and PCManFM configuration"

    mkdir -p "${SKEL}/.config/jgmenu"
    retro_write "${SKEL}/.config/jgmenu/jgmenurc" 0644 <<EOF
stay_alive = 1
tint2_look = 0
csv_cmd = ${RETRO_HELPER_DIR}/retro-jgmenu-csv
position_mode = fixed
menu_halign = left
menu_valign = bottom
menu_margin_x = 0
menu_margin_y = 40
menu_width = 300
menu_padding_top = 6
menu_padding_right = 6
menu_padding_bottom = 6
menu_padding_left = 6
menu_radius = 4
menu_border = 1
item_height = 30
item_margin_y = 2
item_radius = 3
item_border = 0
sep_height = 6
sep_halign = center
icon_size = 22
icon_theme = ${RETRO_ICON_THEME}
font = ${RETRO_UI_FONT} 10
arrow_string = >
sub_hover_action = 1
color_menu_bg = #0c0d12 96
color_menu_border = #00ff9c 70
color_norm_bg = #0c0d12 0
color_norm_fg = #e0e0e0 100
color_sel_bg = #00ff9c 28
color_sel_fg = #ffffff 100
color_sel_border = #00ff9c 60
color_sep_fg = #2b2f3d 100
color_title_bg = #0c0d12 0
color_title_fg = #00ff9c 100
EOF

    mkdir -p "${SKEL}/.config/picom"
    retro_write "${SKEL}/.config/picom/picom.conf" 0644 <<'EOF'
backend = "xrender";
vsync = false;
shadow = false;
fading = false;
active-opacity = 1.0;
inactive-opacity = 0.94;
frame-opacity = 1.0;
inactive-opacity-override = false;
detect-client-opacity = true;
detect-rounded-corners = false;
mark-wmwin-focused = true;
mark-ovredir-focused = true;
use-ewmh-active-win = true;
unredir-if-possible = true;
opacity-rule = [
  "92:class_g = 'Xfce4-terminal'",
  "100:class_g = 'Tint2'",
  "100:class_g = 'Firefox-esr'",
  "100:class_g = 'firefox-esr'"
];
wintypes:
{
  tooltip = { fade = false; shadow = false; opacity = 0.96; focus = true; };
  dock = { shadow = false; };
  dnd = { shadow = false; };
  popup_menu = { opacity = 1.0; };
  dropdown_menu = { opacity = 1.0; };
};
EOF

    mkdir -p "${SKEL}/.config/pcmanfm/default"
    retro_write "${SKEL}/.config/pcmanfm/default/desktop-items-0.conf" 0644 <<EOF
[*]
wallpaper_mode=stretch
wallpaper_common=1
wallpaper=${WALLPAPER}
desktop_bg=${RETRO_BG_COLOR}
desktop_fg=${RETRO_FG_COLOR}
desktop_shadow=#000000
desktop_font=${RETRO_UI_FONT} 10
show_wm_menu=1
sort=mtime;ascending;
show_documents=0
show_trash=0
show_mounts=0
EOF
    retro_write "${SKEL}/.config/pcmanfm/default/pcmanfm.conf" 0644 <<'EOF'
[config]
bm_open_method=0

[volume]
mount_on_startup=1
mount_removable=1
autorun=1

[ui]
always_show_tabs=0
show_hidden=0
view_mode=list
EOF
}

write_skel_theming() {
    retro_info "Writing GTK / terminal / shell theming"
    mkdir -p "${SKEL}/.config/gtk-3.0" "${SKEL}/.config/xfce4/terminal"

    retro_write "${SKEL}/.config/gtk-3.0/settings.ini" 0644 <<EOF
[Settings]
gtk-theme-name=${RETRO_GTK_THEME}
gtk-icon-theme-name=${RETRO_ICON_THEME}
gtk-font-name=${RETRO_UI_FONT} 10
gtk-cursor-theme-name=Adwaita
gtk-application-prefer-dark-theme=1
gtk-enable-animations=false
gtk-button-images=0
gtk-menu-images=0
EOF
    retro_write "${SKEL}/.gtkrc-2.0" 0644 <<EOF
gtk-theme-name="${RETRO_GTK_THEME}"
gtk-icon-theme-name="${RETRO_ICON_THEME}"
gtk-font-name="${RETRO_UI_FONT} 10"
gtk-cursor-theme-name="Adwaita"
gtk-enable-animations=0
EOF

    retro_write "${SKEL}/.config/xfce4/terminal/terminalrc" 0644 <<EOF
[Configuration]
FontName=${RETRO_FONT_NAME} 10
MiscAlwaysShowTabs=FALSE
MiscBell=FALSE
MiscMenubarDefault=FALSE
MiscShowUnsafePasteDialog=FALSE
ScrollingLines=10000
ScrollingBar=TERMINAL_SCROLLBAR_NONE
ColorForeground=${RETRO_FG_COLOR}
ColorBackground=${RETRO_BG_COLOR}
ColorCursor=${RETRO_ACCENT_COLOR}
ColorPalette=#1b1d27;#ff0055;#00ff9c;#ffd166;#4cc9f0;#b388ff;#2ec4b6;#e0e0e0;#3a3f52;#ff4d88;#5affc0;#ffe199;#8be0ff;#d0b3ff;#6ee7d8;#ffffff
EOF

    cat >> "${SKEL}/.bashrc" <<'EOF'
case $- in
    *i*)
        export PATH="${PATH}:/usr/local/sbin:/usr/sbin:/sbin"
        PS1='\[\e[38;5;48m\]\u@\h\[\e[0m\]:\[\e[38;5;75m\]\w\[\e[0m\]\$ '
        alias ll='ls -alF --color=auto'
        alias la='ls -A --color=auto'
        alias ..='cd ..'
        alias grep='grep --color=auto'
        ;;
esac
EOF

    mkdir -p "${SKEL}/Desktop" "${SKEL}/Documents" "${SKEL}/Downloads" "${SKEL}/Pictures" "${SKEL}/.config"
    retro_write "${SKEL}/.config/user-dirs.dirs" 0644 <<'EOF'
XDG_DESKTOP_DIR="$HOME/Desktop"
XDG_DOCUMENTS_DIR="$HOME/Documents"
XDG_DOWNLOAD_DIR="$HOME/Downloads"
XDG_PICTURES_DIR="$HOME/Pictures"
EOF
    retro_write "${SKEL}/.config/user-dirs.locale" 0644 <<'EOF'
en_US
EOF
}

generate_menus() {
    retro_info "Generating Openbox / jgmenu menus + tool launchers"
    "${RETRO_HELPER_DIR}/retro-menu-gen" --system
}

normalise_skel_permissions() {
    chown -R root:root "${SKEL}"
    find "${SKEL}" -type d -exec chmod 0755 {} +
    find "${SKEL}" -type f ! -perm /111 -exec chmod 0644 {} +
}

main() {
    retro_info "=== 02_interface_setup.sh: start ==="
    install_graphical_stack
    install_branding_assets
    write_templates
    install_login_stack
    write_session_start
    write_live_fixup
    write_menu_tools
    write_skel_session
    write_skel_tint2
    write_skel_jgmenu_picom_pcmanfm
    write_skel_theming
    generate_menus
    normalise_skel_permissions
    retro_ok "=== 02_interface_setup.sh: complete ==="
}

main "$@"
