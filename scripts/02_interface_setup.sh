#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 - 02_interface_setup.sh
# Debian Trixie Wayland desktop: Labwc + Waybar + Foot + Wofi.
# LightDM/Xorg is retained only for the graphical login greeter; user sessions
# run on Wayland, with Xwayland for legacy X11 applications.
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

install_graphical_stack() {
    retro_info "Preseeding LightDM as the graphical display manager"
    echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections
    echo "libpam-runtime libpam-runtime/override boolean false" | debconf-set-selections || true

    retro_info "Installing Labwc Wayland desktop and Xwayland compatibility"
    retro_apt_install \
        xserver-xorg xserver-xorg-core xserver-xorg-input-libinput \
        xserver-xorg-video-all xserver-xorg-video-intel xserver-xorg-video-fbdev xserver-xorg-video-vesa \
        xwayland \
        lightdm lightdm-gtk-greeter \
        labwc waybar foot wofi swaybg mako-notifier \
        xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk \
        wl-clipboard grim slurp \
        pcmanfm mousepad lxtask lxappearance \
        network-manager-gnome volumeicon-alsa \
        pkexec polkitd mate-polkit udisks2 \
        arc-theme papirus-icon-theme adwaita-icon-theme gtk2-engines-murrine \
        librsvg2-common fonts-dejavu-core fonts-jetbrains-mono \
        gvfs gvfs-backends gvfs-daemons gvfs-fuse libmtp-runtime jmtpfs \
        cbatticon blueman \
        dillo geany geany-plugins vlc ristretto evince galculator xarchiver p7zip-full unrar-free

    retro_apt_install_optional \
        xserver-xorg-video-vmware xserver-xorg-video-qxl \
        xserver-xorg-video-nouveau xserver-xorg-video-ati xserver-xorg-video-amdgpu \
        kanshi
    if [[ "${RETRO_INSTALL_BROWSER}" == "1" ]]; then
        retro_apt_install_optional firefox-esr
    fi
}

install_branding_assets() {
    retro_info "Installing Retro OS Wayland branding"
    mkdir -p /usr/share/backgrounds/retro-os /usr/share/pixmaps /usr/share/wayland-sessions

    retro_write /usr/share/pixmaps/retro-start.svg 0644 <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
  <defs>
    <radialGradient id="g" cx="35%" cy="30%" r="75%">
      <stop offset="0" stop-color="#7dffd0"/>
      <stop offset="0.55" stop-color="#00ff9c"/>
      <stop offset="1" stop-color="#007a4c"/>
    </radialGradient>
  </defs>
  <circle cx="32" cy="32" r="29" fill="#0c0d12" stroke="#00ff9c" stroke-width="2"/>
  <circle cx="32" cy="32" r="24" fill="url(#g)"/>
  <path d="M23 43V21h10a7 7 0 0 1 0 14h-4l8 8" fill="none" stroke="#0c0d12"
        stroke-width="4.5" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
EOF

    retro_write /usr/share/applications/retro-start.desktop 0644 <<'EOF'
[Desktop Entry]
Type=Application
Name=Retro OS Launcher
Comment=Open the Retro OS application launcher
Exec=wofi --show drun
Icon=/usr/share/pixmaps/retro-start.svg
Terminal=false
Categories=Utility;
EOF

    retro_write /usr/local/bin/retro-labwc-session 0755 <<'EOF'
#!/bin/sh
set -eu
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=labwc
export XDG_SESSION_DESKTOP=labwc
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM='wayland;xcb'
export GDK_BACKEND='wayland,x11'
export SDL_VIDEODRIVER='wayland,x11'
exec /usr/bin/labwc
EOF

    retro_write /usr/share/wayland-sessions/retro-os.desktop 0644 <<'EOF'
[Desktop Entry]
Name=Retro OS (Labwc)
Comment=Lightweight Retro OS Wayland desktop
Exec=/usr/local/bin/retro-labwc-session
Type=Application
DesktopNames=labwc;wlroots;
EOF
}

write_templates() {
    retro_info "Writing LightDM and greeter templates"
    mkdir -p "${TEMPLATE_DIR}"
    retro_write "${TEMPLATE_DIR}/lightdm.conf" 0644 <<'EOF'
[LightDM]
minimum-vt=7

[Seat:*]
user-session=retro-os
greeter-session=lightdm-gtk-greeter
allow-guest=false
greeter-hide-users=false
xserver-command=X -nolisten tcp
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
    retro_info "Installing authenticated LightDM greeter and Labwc Wayland session"
    mkdir -p /etc/lightdm/lightdm.conf.d /etc/X11
    install -m 0644 "${TEMPLATE_DIR}/lightdm.conf" /etc/lightdm/lightdm.conf
    install -m 0644 "${TEMPLATE_DIR}/lightdm.conf" /etc/lightdm/lightdm.conf.d/50-retro-greeter.conf
    install -m 0644 "${TEMPLATE_DIR}/lightdm-gtk-greeter.conf" /etc/lightdm/lightdm-gtk-greeter.conf
    install -m 0644 "${TEMPLATE_DIR}/Xwrapper.config" /etc/X11/Xwrapper.config

    if dpkg --verify lightdm 2>/dev/null | grep -Eq '[[:space:]]/etc/pam.d/lightdm(-autologin|-greeter)?$' ||
       [[ ! -s /etc/pam.d/lightdm || ! -s /etc/pam.d/lightdm-autologin ]]; then
        retro_info "Restoring the package-provided LightDM PAM stack"
        retro_retry 3 5 apt-get \
            -o Dpkg::Options::=--force-confnew \
            -o Dpkg::Options::=--force-confmiss \
            --reinstall install -y lightdm
    fi
    echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
    systemctl enable lightdm.service
    systemctl set-default graphical.target
}

write_session_start() {
    retro_info "Writing Wayland session autostart helper"
    retro_write "${RETRO_HELPER_DIR}/retro-session-start" 0755 <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}"
mkdir -p "${CACHE_DIR}"
exec >>"${CACHE_DIR}/retro-session.log" 2>&1
echo "=== Retro OS Wayland session $(date '+%F %T') ==="

start_once() {
    local process="$1"
    shift
    if pgrep -u "$(id -u)" -x "${process}" >/dev/null 2>&1; then
        return 0
    fi
    command -v "$1" >/dev/null 2>&1 || {
        echo "skip ${process}: executable $1 not found"
        return 0
    }
    "$@" &
}

start_once swaybg swaybg -i /usr/share/backgrounds/retro-os/wallpaper.png -m fill
sleep 0.3
start_once waybar waybar
start_once mako mako
start_once polkit-mate-authentication-agent-1 /usr/libexec/polkit-mate-authentication-agent-1
start_once nm-applet nm-applet --indicator
start_once volumeicon volumeicon
start_once blueman-applet blueman-applet
start_once parcellite parcellite
start_once cbatticon cbatticon -u 5

if grep -qw 'retro.install=1' /proc/cmdline 2>/dev/null && command -v calamares >/dev/null 2>&1; then
    pkexec calamares &
fi
EOF
}

write_live_fixup() {
    retro_info "Writing live-session account and credential helpers"
    retro_write "${RETRO_HELPER_DIR}/retro-live-fixup" 0750 <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

USER_NAME="retro"
USER_UID="1000"
TAG="retro-live-fixup"
log() { logger -t "${TAG}" -- "$*" 2>/dev/null || true; echo "[${TAG}] $*"; }

grep -qw 'boot=live' /proc/cmdline || exit 0

for g in wireshark audio video plugdev netdev sudo; do
    getent group "${g}" >/dev/null || { groupadd --system "${g}"; log "created group ${g}"; }
done

if ! id -u "${USER_NAME}" >/dev/null 2>&1; then
    useradd --create-home --uid "${USER_UID}" --user-group --shell /bin/bash \
        --comment "Retro OS Live User" "${USER_NAME}"
    cp -a /etc/skel/. "/home/${USER_NAME}/" 2>/dev/null || true
fi

usermod --append --groups sudo,audio,video,plugdev,netdev,wireshark "${USER_NAME}"
for g in autologin nopasswdlogin; do gpasswd -d "${USER_NAME}" "${g}" >/dev/null 2>&1 || true; done
usermod --shell /bin/bash "${USER_NAME}"
passwd --lock "${USER_NAME}" >/dev/null 2>&1 || true
rm -f /etc/sudoers.d/90-retro-nopasswd
rm -f /etc/lightdm/lightdm.conf.d/50-retro-autologin.conf
if grep -qw 'retro.report=1' /proc/cmdline; then
    cat > /etc/lightdm/lightdm.conf.d/50-retro-report-autologin.conf <<'EOT'
[Seat:*]
autologin-user=retro
autologin-user-timeout=0
autologin-session=retro-os
EOT
    chmod 0644 /etc/lightdm/lightdm.conf.d/50-retro-report-autologin.conf
else
    rm -f /etc/lightdm/lightdm.conf.d/50-retro-report-autologin.conf
fi

sync_file() {
    local src="$1" dst="$2" mode="$3"
    [[ -r "${src}" ]] || return 0
    if ! cmp -s "${src}" "${dst}" 2>/dev/null; then
        mkdir -p "$(dirname "${dst}")"
        install -m "${mode}" "${src}" "${dst}"
        log "restored ${dst}"
    fi
}
sync_file /opt/retro-os/templates/lightdm.conf /etc/lightdm/lightdm.conf 0644
sync_file /opt/retro-os/templates/lightdm.conf /etc/lightdm/lightdm.conf.d/50-retro-greeter.conf 0644
sync_file /opt/retro-os/templates/Xwrapper.config /etc/X11/Xwrapper.config 0644

home="/home/${USER_NAME}"
if [[ -d "${home}" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "${home}"
    [[ -d "${home}/.config/labwc" ]] || cp -a /etc/skel/.config/labwc "${home}/.config/"
fi

chmod 1777 /tmp /var/tmp 2>/dev/null || true
mkdir -p /var/lib/lightdm /var/cache/lightdm /var/log/lightdm
chown lightdm:lightdm /var/lib/lightdm /var/cache/lightdm 2>/dev/null || true
log "live account prepared"
EOF

    retro_write "${RETRO_HELPER_DIR}/retro-live-credentials" 0750 <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
grep -qw 'boot=live' /proc/cmdline || exit 0
id retro >/dev/null 2>&1 || { echo "retro live user is missing" >&2; exit 1; }

password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
[[ "${#password}" -eq 48 ]] || { echo "credential generation failed" >&2; exit 1; }
printf 'retro:%s\n' "${password}" | chpasswd
passwd --unlock retro >/dev/null
{
    printf '\n\nRetro OS temporary live-session login\n'
    printf 'Username: retro\n'
    printf 'Password: %s\n' "${password}"
    printf 'Use Ctrl+Alt+F7 to return to the graphical greeter.\n'
} > /dev/tty1
unset password
EOF

    retro_write /etc/systemd/system/retro-live-credentials.service 0644 <<'EOF'
[Unit]
Description=Generate one-boot credentials for Retro OS live session
After=retro-live-fixup.service live-config.service local-fs.target
Before=display-manager.service lightdm.service
ConditionKernelCommandLine=boot=live

[Service]
Type=oneshot
ExecStart=/opt/retro-os/bin/retro-live-credentials
StandardOutput=null
StandardError=journal
TimeoutStartSec=30

[Install]
WantedBy=graphical.target multi-user.target
EOF

    retro_write /etc/systemd/system/retro-live-fixup.service 0644 <<'EOF'
[Unit]
Description=Prepare the Retro OS live account and greeter
After=live-config.service local-fs.target
Before=retro-live-credentials.service display-manager.service lightdm.service
ConditionKernelCommandLine=boot=live

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/retro-os/bin/retro-live-fixup

[Install]
WantedBy=graphical.target multi-user.target
EOF
    systemctl enable retro-live-fixup.service retro-live-credentials.service
}

write_menu_tools() {
    retro_info "Installing Wayland menu generator and security tool catalogue"
    mkdir -p "${RETRO_ROOT}/menu.d"
    retro_write "${RETRO_ROOT}/menu.d/10-security.list" 0644 <<'EOF'
Reconnaissance|Nmap (CLI)|nmap|--help|utilities-terminal|CLI
Reconnaissance|Nmap GUI (NmapSI4)|nmapsi4||utilities-terminal|GUI
Reconnaissance|RustScan|rustscan|--help|utilities-terminal|CLI
Reconnaissance|Naabu|naabu|--help|utilities-terminal|CLI
Reconnaissance|httpx|httpx|--help|utilities-terminal|CLI
Web Audit|Nikto|nikto|-Help|utilities-terminal|CLI
Web Audit|SQLMap|sqlmap|--help|utilities-terminal|CLI
Web Audit|ffuf|ffuf|--help|utilities-terminal|CLI
Passwords|Hydra (CLI)|hydra|--help|utilities-terminal|CLI
Passwords|Hydra GUI (XHydra)|xhydra||security-high|GUI
Passwords|John the Ripper|john||utilities-terminal|CLI
Passwords|Johnny GUI|johnny||security-high|GUI
Wireless|Aircrack-ng|aircrack-ng|--help|utilities-terminal|CLI
Wireless|Wifite|wifite||utilities-terminal|CLI
Sniffing|Tshark|tshark|--help|utilities-terminal|CLI
Sniffing|Wireshark|wireshark||wireshark|GUI
Firewall|Gufw Firewall|gufw||security-high|GUI
EOF

    retro_write "${RETRO_HELPER_DIR}/retro-menu-gen" 0755 <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

LIST_DIR="${RETRO_MENU_LIST_DIR:-/opt/retro-os/menu.d}"
ROOT="${RETRO_MENU_ROOT:-}"
MARK="retro-os:generated"
declare -a CAT_ORDER=()
declare -A CAT_ITEMS=()

die() { echo "retro-menu-gen: $*" >&2; exit 1; }
have() { [[ -n "${RETRO_MENU_ASSUME_ALL:-}" ]] && return 0; command -v "$1" >/dev/null 2>&1; }
xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "${s}"
}
load_entries() {
    local f line cat label bin args icon mtype
    shopt -s nullglob
    for f in "${LIST_DIR}"/*.list; do
        while IFS= read -r line || [[ -n "${line}" ]]; do
            [[ -z "${line//[[:space:]]/}" || "${line}" =~ ^[[:space:]]*# ]] && continue
            IFS='|' read -r cat label bin args icon mtype <<< "${line}"
            [[ -n "${cat}" && -n "${label}" && -n "${bin}" ]] || continue
            have "${bin}" || continue
            if [[ -z "${CAT_ITEMS[${cat}]+x}" ]]; then
                CAT_ORDER+=("${cat}")
                CAT_ITEMS["${cat}"]=""
            fi
            CAT_ITEMS["${cat}"]+="${label}|${bin}|${args}|${icon}|${mtype}"$'\n'
        done < "${f}"
    done
}
item() {
    printf '  <item label="%s"><action name="Execute" command="%s"/></item>\n' \
        "$(xml_escape "$1")" "$(xml_escape "$2")"
}
build_menu() {
    local cat label bin args icon mtype index=0 command
    printf '<?xml version="1.0"?>\n<openbox_menu>\n<menu id="root-menu" label="Retro OS">\n'
    item "Application Launcher" "wofi --show drun"
    item "Terminal (Foot)" "foot"
    item "File Manager" "pcmanfm"
    if have firefox-esr; then item "Web Browser" "firefox-esr"; fi
    item "Text Editor" "mousepad"
    printf '  <separator/>\n'
    if (( ${#CAT_ORDER[@]} > 0 )); then
        for cat in "${CAT_ORDER[@]}"; do
            index=$((index + 1))
            printf '  <menu id="retro-sec-%d" label="%s">\n' "${index}" "$(xml_escape "${cat}")"
            while IFS='|' read -r label bin args icon mtype; do
                [[ -n "${label}" ]] || continue
                if [[ "${mtype}" == "GUI" ]]; then
                    command="${bin} ${args}"
                else
                    command="foot --hold -e bash -lc '${bin} ${args}; printf \"\\nPress Enter to close...\"; read -r; exec bash -i'"
                fi
                item "${label}" "${command}"
            done <<< "${CAT_ITEMS[${cat}]}"
            printf '  </menu>\n'
        done
    fi
    printf '  <separator/>\n'
    item "Retro Boost" "foot --hold -e sudo retro boost"
    item "Retro Doctor" "foot --hold -e sudo retro doctor"
    item "Retro Update" "foot --hold -e sudo retro update"
    item "Retro AI" "foot -e retro ai"
    item "System Monitor" "foot -e btop"
    item "System Information" "foot -e retro fetch"
    item "Network Connections" "nm-connection-editor"
    if have calamares; then item "Install Retro OS" "pkexec calamares"; fi
    item "Lock Screen" "dm-tool lock"
    item "Reconfigure Labwc" "labwc --reconfigure"
    item "Log Out" "labwc --exit"
    item "Reboot" "systemctl reboot"
    item "Shut Down" "systemctl poweroff"
    printf '</menu>\n</openbox_menu>\n'
}
atomic_write() {
    local dest="$1" tmp
    mkdir -p "$(dirname "${dest}")"
    tmp="$(mktemp "${dest}.XXXXXX")"
    cat > "${tmp}"
    chmod 0644 "${tmp}"
    mv -f "${tmp}" "${dest}"
}
write_menu() {
    local home="$1"
    build_menu | atomic_write "${home}/.config/labwc/menu.xml"
}
main() {
    case "${1:-}" in
        --system)
            load_entries
            write_menu /etc/skel
            ;;
        --user)
            local home="${2:-${HOME}}"
            [[ -d "${home}" ]] || die "home directory not found: ${home}"
            load_entries
            write_menu "${home}"
            if [[ "$(id -u)" -eq 0 ]]; then
                local owner
                owner="$(stat -c %U:%G "${home}")"
                chown "${owner}" "${home}/.config/labwc" "${home}/.config/labwc/menu.xml"
            fi
            ;;
        --list)
            load_entries
            printf '%s\n' "${CAT_ORDER[@]}"
            ;;
        *)
            echo "usage: retro-menu-gen {--system|--user HOME|--list}" >&2
            exit 2
            ;;
    esac
}
main "$@"
EOF
}

write_skel_session() {
    retro_info "Writing Labwc session, Waybar panel, Wofi launcher and Foot terminal config"
    mkdir -p "${SKEL}/.config/labwc" "${SKEL}/.config/waybar" "${SKEL}/.config/wofi" "${SKEL}/.config/foot"

    retro_write "${SKEL}/.config/labwc/rc.xml" 0644 <<'EOF'
<?xml version="1.0"?>
<labwc_config>
  <theme>
    <cornerRadius>3</cornerRadius>
    <font name="JetBrains Mono" size="10"/>
  </theme>
  <keyboard>
    <default/>
    <keybind key="W-Return"><action name="Execute" command="foot"/></keybind>
    <keybind key="C-A-t"><action name="Execute" command="foot"/></keybind>
    <keybind key="W-d"><action name="Execute" command="wofi --show drun"/></keybind>
    <keybind key="A-F2"><action name="Execute" command="wofi --show run"/></keybind>
    <keybind key="W-e"><action name="Execute" command="pcmanfm"/></keybind>
    <keybind key="W-l"><action name="Execute" command="dm-tool lock"/></keybind>
    <keybind key="W-m"><action name="Execute" command="foot -e btop"/></keybind>
    <keybind key="Print"><action name="Execute" command="sh -c 'grim &quot;$HOME/Pictures/retro-$(date +%F-%H%M%S).png&quot;'"/></keybind>
    <keybind key="W-F4"><action name="Exit"/></keybind>
  </keyboard>
  <mouse><default/></mouse>
</labwc_config>
EOF

    retro_write "${SKEL}/.config/labwc/themerc-override" 0644 <<'EOF'
border.width: 2
window.active.border.color: #00ff9c
window.inactive.border.color: #3a3f52
window.active.title.bg.color: #0c0d12
window.inactive.title.bg.color: #1b1d27
window.active.label.text.color: #00ff9c
window.inactive.label.text.color: #e0e0e0
window.active.button.unpressed.image.color: #00ff9c
window.inactive.button.unpressed.image.color: #8c93a8
menu.border.width: 1
menu.border.color: #00ff9c
menu.items.bg.color: #0c0d12
menu.items.text.color: #e0e0e0
menu.items.active.bg.color: #00ff9c
menu.items.active.text.color: #0c0d12
menu.title.bg.color: #1b1d27
menu.title.text.color: #00ff9c
EOF
    retro_write "${SKEL}/.config/labwc/environment" 0644 <<'EOF'
XKB_DEFAULT_LAYOUT=us
XCURSOR_THEME=Adwaita
XCURSOR_SIZE=24
XDG_CURRENT_DESKTOP=labwc
XDG_SESSION_TYPE=wayland
MOZ_ENABLE_WAYLAND=1
QT_QPA_PLATFORM=wayland;xcb
GDK_BACKEND=wayland,x11
SDL_VIDEODRIVER=wayland,x11
EOF

    retro_write "${SKEL}/.config/labwc/autostart" 0755 <<EOF
#!/bin/sh
"${RETRO_HELPER_DIR}/retro-session-start" &
EOF

    retro_write "${SKEL}/.config/waybar/config" 0644 <<'EOF'
{
  "layer": "top",
  "position": "bottom",
  "height": 34,
  "spacing": 8,
  "modules-left": ["custom/launcher", "clock"],
  "modules-center": ["cpu", "memory"],
  "modules-right": ["network", "custom/audio", "tray", "battery"],
  "custom/launcher": {
    "format": "  RETRO",
    "tooltip": false,
    "on-click": "wofi --show drun"
  },
  "clock": {
    "format": "{:%a %d %b  %H:%M}",
    "tooltip-format": "{:%A, %d %B %Y}"
  },
  "cpu": {
    "format": "CPU {usage}%",
    "interval": 5
  },
  "memory": {
    "format": "RAM {used:0.1f}G",
    "interval": 5
  },
  "network": {
    "format-wifi": "WIFI {essid}",
    "format-ethernet": "LAN {ifname}",
    "format-disconnected": "OFFLINE",
    "tooltip": true,
    "interval": 5
  },
  "custom/audio": {
    "format": "VOL {}",
    "exec": "amixer get Master 2>/dev/null | grep -o '[0-9][0-9]*%' | head -n1",
    "interval": 3,
    "on-click": "foot -e alsamixer"
  },
  "tray": {
    "icon-size": 16,
    "spacing": 8
  },
  "battery": {
    "format": "BAT {capacity}%",
    "format-charging": "CHG {capacity}%",
    "states": {"warning": 25, "critical": 10}
  }
}
EOF

    retro_write "${SKEL}/.config/waybar/style.css" 0644 <<'EOF'
* {
  font-family: "JetBrains Mono", "DejaVu Sans", sans-serif;
  font-size: 11px;
  min-height: 0;
}
window#waybar {
  background: rgba(12, 13, 18, 0.96);
  color: #e0e0e0;
  border-top: 1px solid #00ff9c;
}
#custom-launcher {
  color: #0c0d12;
  background: #00ff9c;
  font-weight: bold;
  padding: 0 14px;
}
#clock, #cpu, #memory, #network, #custom-audio, #tray, #battery {
  padding: 0 10px;
}
#network.disconnected, #battery.critical {
  color: #ff0055;
}
#battery.warning {
  color: #ffd166;
}
EOF

    retro_write "${SKEL}/.config/wofi/style.css" 0644 <<'EOF'
window {
  background-color: #0c0d12;
  color: #e0e0e0;
  border: 1px solid #00ff9c;
  border-radius: 4px;
}
#input {
  margin: 8px;
  border: 1px solid #00ff9c;
  background: #1b1d27;
  color: #e0e0e0;
}
#inner-box, #outer-box {
  margin: 4px;
  background-color: #0c0d12;
}
#entry:selected {
  background-color: #00ff9c;
  color: #0c0d12;
}
EOF

    retro_write "${SKEL}/.config/foot/foot.ini" 0644 <<EOF
[main]
font=${RETRO_FONT_NAME}:size=10
pad=8x8
term=xterm-256color
[colors]
foreground=${RETRO_FG_COLOR}
background=${RETRO_BG_COLOR}
regular0=#1b1d27
regular1=#ff0055
regular2=#00ff9c
regular3=#ffd166
regular4=#4cc9f0
regular5=#b388ff
regular6=#2ec4b6
regular7=#e0e0e0
bright0=#3a3f52
bright1=#ff4d88
bright2=#5affc0
bright3=#ffe199
bright4=#8be0ff
bright5=#d0b3ff
bright6=#6ee7d8
bright7=#ffffff
EOF
}

write_skel_theming() {
    retro_info "Writing GTK theme, shell and XDG user-directory defaults"
    mkdir -p "${SKEL}/.config/gtk-3.0" "${SKEL}/.config/gtk-4.0"
    retro_write "${SKEL}/.config/gtk-3.0/settings.ini" 0644 <<EOF
[Settings]
gtk-theme-name=${RETRO_GTK_THEME}
gtk-icon-theme-name=${RETRO_ICON_THEME}
gtk-font-name=${RETRO_UI_FONT} 10
gtk-cursor-theme-name=Adwaita
gtk-application-prefer-dark-theme=1
gtk-enable-animations=false
EOF
    retro_write "${SKEL}/.config/gtk-4.0/settings.ini" 0644 <<EOF
[Settings]
gtk-theme-name=${RETRO_GTK_THEME}
gtk-icon-theme-name=${RETRO_ICON_THEME}
gtk-font-name=${RETRO_UI_FONT} 10
gtk-cursor-theme-name=Adwaita
gtk-application-prefer-dark-theme=1
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
    retro_info "Generating Labwc root menu for the Wayland desktop"
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
    write_skel_theming
    generate_menus
    normalise_skel_permissions
    retro_ok "=== 02_interface_setup.sh: complete (Labwc + Waybar + Foot) ==="
}

main "$@"
