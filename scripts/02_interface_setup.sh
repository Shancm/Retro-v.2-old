#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 - 02_interface_setup.sh
# Debian Trixie X11 desktop: Openbox + Tint2 + LXTerminal + jgmenu.
# LightDM launches the Retro OS Openbox session directly on Xorg.
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
WALLPAPER="/usr/share/backgrounds/retro-wallpaper.png"

install_graphical_stack() {
    retro_info "Installing lightweight X11 desktop, Bluetooth, network and audio packages"
    echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections
    echo "libpam-runtime libpam-runtime/override boolean false" | debconf-set-selections || true
    retro_apt_install \
        xserver-xorg-core xserver-xorg-video-all xserver-xorg-video-vesa \
        xserver-xorg-video-nouveau xserver-xorg-input-all x11-xserver-utils \
        lightdm lightdm-gtk-greeter openbox obconf tint2 jgmenu \
        pcmanfm lxterminal feh xarchiver gvfs gvfs-backends \
        network-manager-gnome bluetooth bluez bluez-tools bluez-obexd blueman \
        usb-modeswitch usbmuxd ipheth-utils wireless-tools wpasupplicant \
        firmware-linux-nonfree firmware-realtek firmware-atheros firmware-misc-nonfree \
        pipewire pipewire-pulse wireplumber pavucontrol volumeicon-alsa alsa-utils \
        pkexec polkitd mate-polkit udisks2 \
        arc-theme papirus-icon-theme adwaita-icon-theme gtk2-engines-murrine \
        librsvg2-common fonts-dejavu-core fonts-jetbrains-mono \
        mousepad lxtask lxappearance dillo geany geany-plugins \
        vlc ristretto evince galculator p7zip-full unrar-free

    # Debian Trixie alsa-utils 1.2.14-1 can ship GOTO="alsa_restore_std"
    # while the corresponding label is still named alsa_restore_go.
    local alsa_rule="/usr/lib/udev/rules.d/90-alsa-restore.rules"
    local alsa_override="/etc/udev/rules.d/90-alsa-restore.rules"
    if [[ -f "${alsa_rule}" ]] &&
       grep -q 'GOTO="alsa_restore_std"' "${alsa_rule}" &&
       ! grep -q 'LABEL="alsa_restore_std"' "${alsa_rule}" &&
       grep -q 'LABEL="alsa_restore_go"' "${alsa_rule}"; then
        mkdir -p /etc/udev/rules.d
        install -m 0644 "${alsa_rule}" "${alsa_override}"
        sed -i \
            -e 's/GOTO="alsa_restore_go"/GOTO="alsa_restore_std"/g' \
            -e 's/LABEL="alsa_restore_go"/LABEL="alsa_restore_std"/g' \
            "${alsa_override}"
        grep -q 'LABEL="alsa_restore_std"' "${alsa_override}" \
            || retro_die "failed to repair ALSA restore udev labels"
        retro_warn "Applied persistent ALSA udev label compatibility fix in /etc/udev/rules.d"
        udevadm control --reload-rules 2>/dev/null || true
    fi

    # Prevent the optional Evolution address-book plugin from probing EDS
    # on minimal desktops; OBEX file transfer and phonebook-independent plugins remain.
    mkdir -p /etc/systemd/user/obex.service.d
    retro_write /etc/systemd/user/obex.service.d/override.conf 0644 <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/libexec/bluetooth/obexd --noplugin=ebook,mas
EOF

    retro_apt_install_optional \
        xserver-xorg-video-intel xserver-xorg-video-fbdev \
        xserver-xorg-video-vmware xserver-xorg-video-qxl \
        xserver-xorg-video-ati xserver-xorg-video-amdgpu
    if [[ "${RETRO_INSTALL_BROWSER}" == "1" ]]; then
        retro_apt_install_optional firefox-esr
    fi
}

install_branding_assets() {
    retro_info "Installing Retro OS X11 branding and Openbox session"
    mkdir -p /usr/share/backgrounds /usr/share/pixmaps /usr/share/xsessions /usr/share/applications /usr/share/retro-os
    python3 - "/usr/share/backgrounds/retro-wallpaper.png" <<'PY'
import struct
import sys
import zlib

W, H = 1280, 800
STOPS = [(0.00, (35, 145, 220)), (0.34, (20, 190, 175)),
         (0.67, (125, 92, 205)), (1.00, (245, 145, 72))]

def chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)

def color_at(t, y):
    for i in range(len(STOPS) - 1):
        p0, c0 = STOPS[i]
        p1, c1 = STOPS[i + 1]
        if t <= p1:
            q = (t - p0) / (p1 - p0)
            break
    else:
        q, c0, c1 = 1.0, STOPS[-2][1], STOPS[-1][1]
    lift = int(18 * (1.0 - y / (H - 1)))
    return tuple(max(1, min(255, int(c0[k] + (c1[k] - c0[k]) * q) + lift)) for k in range(3))

raw = bytearray()
for y in range(H):
    raw.append(0)
    for x in range(W):
        raw.extend(color_at(x / (W - 1), y))
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(bytes(raw), 7))
       + chunk(b"IEND", b""))
with open(sys.argv[1], "wb") as fh:
    fh.write(png)
PY
    chmod 0644 /usr/share/backgrounds/retro-wallpaper.png
    retro_write /usr/share/pixmaps/retro-start.svg 0644 <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
  <defs><radialGradient id="g" cx="35%" cy="30%" r="75%"><stop offset="0" stop-color="#7dffd0"/><stop offset=".55" stop-color="#00ff9c"/><stop offset="1" stop-color="#007a4c"/></radialGradient></defs>
  <circle cx="32" cy="32" r="29" fill="#0c0d12" stroke="#00ff9c" stroke-width="2"/>
  <circle cx="32" cy="32" r="24" fill="url(#g)"/>
  <path d="M23 43V21h10a7 7 0 0 1 0 14h-4l8 8" fill="none" stroke="#0c0d12" stroke-width="4.5" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
EOF
    retro_write /usr/share/retro-os/retro-start.desktop 0644 <<'EOF'
[Desktop Entry]
Type=Application
Name=Retro OS Start
Comment=Open the Retro OS application menu
Exec=jgmenu_run
Icon=/usr/share/pixmaps/retro-start.svg
Terminal=false
Categories=Utility;
EOF
    retro_write /usr/share/xsessions/retro-os.desktop 0644 <<'EOF'
[Desktop Entry]
Name=Retro OS (Openbox)
Comment=Lightweight Retro OS X11 desktop
Exec=openbox-session
Type=Application
DesktopNames=Openbox;
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
    retro_info "Installing authenticated LightDM greeter and Openbox X11 session"
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
    [[ -d "${home}/.config/openbox" ]] || cp -a /etc/skel/.config/openbox "${home}/.config/"
    chown -R "${USER_NAME}:${USER_NAME}" "${home}"
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

# Keep the documented Retro OS live-session login unchanged.
# The live account uses the established password: retro.
printf 'retro:retro\n' | chpasswd
passwd --unlock retro >/dev/null
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
    retro_info "Installing Openbox root-menu generator"
    mkdir -p "${RETRO_ROOT}/menu.d"
    retro_write "${RETRO_ROOT}/menu.d/10-security.list" 0644 <<'EOF'
Reconnaissance|Nmap|nmap|--help|utilities-terminal|CLI
Reconnaissance|RustScan|rustscan|--help|utilities-terminal|CLI
Reconnaissance|Naabu|naabu|--help|utilities-terminal|CLI
Reconnaissance|ProjectDiscovery httpx|httpx|--help|utilities-terminal|CLI
Web Audit|Nikto|nikto|-Help|utilities-terminal|CLI
Web Audit|SQLMap|sqlmap|--help|utilities-terminal|CLI
Web Audit|ffuf|ffuf|--help|utilities-terminal|CLI
Passwords|Hydra|hydra|--help|utilities-terminal|CLI
Passwords|John the Ripper|john||utilities-terminal|CLI
Wireless|Aircrack-ng|aircrack-ng|--help|utilities-terminal|CLI
Wireless|Wifite|wifite||utilities-terminal|CLI
Sniffing|Tshark|tshark|--help|utilities-terminal|CLI
Sniffing|Wireshark|wireshark||wireshark|GUI
EOF

    retro_write "${RETRO_HELPER_DIR}/retro-menu-gen" 0755 <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
LIST_DIR="${RETRO_MENU_LIST_DIR:-/opt/retro-os/menu.d}"
declare -a CAT_ORDER=()
declare -A CAT_ITEMS=()
die() { echo "retro-menu-gen: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}
load_entries() {
    local f line cat label bin args icon mtype
    shopt -s nullglob
    for f in "${LIST_DIR}"/*.list; do
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
            IFS='|' read -r cat label bin args icon mtype <<< "$line"
            [[ -n "$cat" && -n "$label" && -n "$bin" ]] || continue
            have "$bin" || continue
            if [[ -z "${CAT_ITEMS[$cat]+x}" ]]; then
                CAT_ORDER+=("$cat")
                CAT_ITEMS["$cat"]=""
            fi
            CAT_ITEMS["$cat"]+="$label|$bin|$args|$icon|$mtype"$'\n'
        done < "$f"
    done
}
item() {
    printf '  <item label="%s"><action name="Execute"><command>%s</command></action></item>\n' \
        "$(xml_escape "$1")" "$(xml_escape "$2")"
}
build_menu() {
    local cat label bin args icon mtype index=0 command
    printf '<?xml version="1.0"?>\n<openbox_menu>\n<menu id="root-menu" label="Retro OS">\n'
    item "Applications" "jgmenu_run"
    item "Terminal" "lxterminal"
    item "File Manager" "pcmanfm"
    item "Text Editor" "mousepad"
    printf '  <separator/>\n'
    for cat in "${CAT_ORDER[@]}"; do
        index=$((index + 1))
        printf '  <menu id="retro-sec-%d" label="%s">\n' "$index" "$(xml_escape "$cat")"
        while IFS='|' read -r label bin args icon mtype; do
            [[ -n "$label" ]] || continue
            if [[ "$mtype" == "GUI" ]]; then command="$bin $args"; else command="lxterminal -e $bin $args"; fi
            item "$label" "$command"
        done <<< "${CAT_ITEMS[$cat]}"
        printf '  </menu>\n'
    done
    printf '  <separator/>\n'
    item "Retro Boost" "lxterminal -e sudo retro boost"
    item "Retro Doctor" "lxterminal -e sudo retro doctor"
    item "Retro Update" "lxterminal -e sudo retro update"
    item "Retro AI" "lxterminal -e retro ai"
    item "System Monitor" "lxterminal -e btop"
    item "System Information" "lxterminal -e retro fetch"
    item "Network Connections" "nm-connection-editor"
    if have calamares; then item "Install Retro OS" "pkexec calamares"; fi
    item "Reconfigure Openbox" "openbox --reconfigure"
    item "Log Out" "openbox --exit"
    item "Reboot" "systemctl reboot"
    item "Shut Down" "systemctl poweroff"
    printf '</menu>\n</openbox_menu>\n'
}
atomic_write() {
    local dest="$1" tmp
    mkdir -p "$(dirname "$dest")"
    tmp="$(mktemp "$dest.XXXXXX")"
    cat > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$dest"
}
write_menu() {
    local home="$1"
    build_menu | atomic_write "$home/.config/openbox/menu.xml"
}
main() {
    case "${1:-}" in
        --system) load_entries; write_menu /etc/skel ;;
        --user)
            local home="${2:-${HOME}}"
            [[ -d "$home" ]] || die "home directory not found: $home"
            load_entries
            write_menu "$home"
            if [[ "$(id -u)" -eq 0 ]]; then
                local owner
                owner="$(stat -c %U:%G "$home")"
                chown "$owner" "$home/.config/openbox" "$home/.config/openbox/menu.xml"
            fi
            ;;
        --list) load_entries; printf '%s\n' "${CAT_ORDER[@]}" ;;
        *) echo "usage: retro-menu-gen {--system|--user HOME|--list}" >&2; exit 2 ;;
    esac
}
main "$@"
EOF
}

write_skel_session() {
    retro_info "Writing Windows 7-style Openbox + Tint2 + jgmenu configuration"
    mkdir -p /etc/skel/.config/openbox /etc/skel/.config/tint2 /etc/skel/.config/jgmenu

    retro_write /etc/skel/.config/openbox/rc.xml 0644 <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <resistance><strength>10</strength><screen_edge_strength>20</screen_edge_strength></resistance>
  <focus><focusNew>yes</focusNew><followMouse>no</followMouse><raiseOnFocus>yes</raiseOnFocus><underMouse>no</underMouse><focusLast>yes</focusLast></focus>
  <placement><policy>Smart</policy><center>yes</center><monitor>Primary</monitor></placement>
  <theme><name>Clearlooks</name><titleLayout>NLIMC</titleLayout><keepBorder>yes</keepBorder><animateIconify>no</animateIconify></theme>
  <desktops><number>2</number><firstdesk>1</firstdesk><names><name>Desktop 1</name><name>Desktop 2</name></names><popupTime>0</popupTime></desktops>
  <resize><drawContents>yes</drawContents><popupShow>Nonpixel</popupShow><popupPosition>Center</popupPosition><popupFixed>no</popupFixed></resize>
  <keyboard>
    <chainQuitKey>C-g</chainQuitKey>
    <keybind key="W-Return"><action name="Execute"><command>lxterminal</command></action></keybind>
    <keybind key="C-A-t"><action name="Execute"><command>lxterminal</command></action></keybind>
    <keybind key="W-d"><action name="Execute"><command>jgmenu_run</command></action></keybind>
    <keybind key="A-F2"><action name="Execute"><command>jgmenu_run</command></action></keybind>
    <keybind key="W-e"><action name="Execute"><command>pcmanfm</command></action></keybind>
    <keybind key="W-l"><action name="Execute"><command>dm-tool lock</command></action></keybind>
    <keybind key="W-m"><action name="Execute"><command>lxterminal -e btop</command></action></keybind>
    <keybind key="W-F4"><action name="Close"/></keybind>
  </keyboard>
  <mouse>
    <context name="Root">
      <mousebind button="Right" action="Press"><action name="ShowMenu"><menu>root-menu</menu></action></mousebind>
      <mousebind button="Up" action="Click"><action name="DesktopPrevious"><wrap>yes</wrap></action></mousebind>
      <mousebind button="Down" action="Click"><action name="DesktopNext"><wrap>yes</wrap></action></mousebind>
    </context>
    <context name="Titlebar">
      <mousebind button="Left" action="Drag"><action name="Move"/></mousebind>
      <mousebind button="Right" action="Press"><action name="ShowMenu"><menu>client-menu</menu></action></mousebind>
    </context>
    <context name="Close">
      <mousebind button="Left" action="Click"><action name="Close"/></mousebind>
    </context>
  </mouse>
  <menu><file>menu.xml</file><hideDelay>200</hideDelay><middle>no</middle><submenuShowDelay>100</submenuShowDelay><submenuHideDelay>400</submenuHideDelay><manageDesktops>yes</manageDesktops></menu>
  <applications/>
</openbox_config>
EOF

    local autostart
    for autostart in /etc/skel/.config/openbox/autostart /etc/xdg/openbox/autostart; do
        mkdir -p "$(dirname "${autostart}")"
        retro_write "${autostart}" 0755 <<'EOF'
#!/bin/sh
xset s off -dpms s noblank &
# PCManFM owns the desktop wallpaper. Do not force the factory wallpaper here:
# user-selected wallpaper settings live in the persistent home directory.
pcmanfm --desktop &
tint2 &
nm-applet &
blueman-applet &
flock -n "${XDG_RUNTIME_DIR:-/tmp}/retro-volumeicon-${UID}.lock" volumeicon &
if [ -x /usr/libexec/polkit-mate-authentication-agent-1 ]; then
    /usr/libexec/polkit-mate-authentication-agent-1 &
fi
EOF
    done

    local pcmanfm_conf
    for pcmanfm_conf in /etc/skel/.config/pcmanfm/default/desktop-items-0.conf /etc/xdg/pcmanfm/default/desktop-items-0.conf; do
        mkdir -p "$(dirname "${pcmanfm_conf}")"
        retro_write "${pcmanfm_conf}" 0644 <<'EOF'
[*]
wallpaper_mode=stretch
wallpapers_configured=1
wallpaper=/usr/share/backgrounds/retro-wallpaper.png
desktop_bg=#1e3a5f
desktop_fg=#ffffff
EOF
    done

    retro_write /etc/skel/.config/tint2/tint2rc 0644 <<'EOF'
# Background 1: panel
rounded = 0
border_width = 1
background_color = #1b1d27 100
border_color = #3a3f52 100

# Background 2: active task
rounded = 2
border_width = 1
background_color = #2c3448 100
border_color = #00ff9c 100

# Background 3: urgent task
rounded = 2
border_width = 1
background_color = #ff0055 100
border_color = #ff0055 100

# Panel
panel_monitor = primary
panel_position = bottom center horizontal
panel_size = 100% 32
panel_margin = 0 0
panel_padding = 4 2 4
panel_background_id = 1
panel_items = LTSC
panel_dock = 0
panel_layer = bottom
strut_policy = follow_size
disable_transparency = 1
wm_menu = 1

# Launcher (Start button)
launcher_padding = 5 2 5
launcher_background_id = 0
launcher_icon_size = 24
launcher_icon_theme = Papirus-Dark
launcher_icon_theme_override = 1
launcher_tooltip = 1
launcher_item_app = /usr/share/retro-os/retro-start.desktop

# Taskbar
taskbar_mode = single_desktop
taskbar_padding = 2 1 2
taskbar_background_id = 0
taskbar_active_background_id = 2
taskbar_sort_order = none
task_align = left
taskbar_name = 0

# Task buttons: show both application icon and window title
task_icon = 1
task_text = 1
task_centered = 0
task_tooltip = 1
task_maximum_size = 200 28
task_padding = 4 2 2
task_background_id = 0
task_active_background_id = 2
task_urgent_background_id = 3
task_iconified_background_id = 0
task_font = DejaVu Sans 9
task_font_color = #e0e0e0 100
task_active_font_color = #ffffff 100
task_urgent_font_color = #ffffff 100
task_iconified_font_color = #9ba3b4 100

# System tray: NetworkManager, Blueman and volume icons
systray_padding = 4 2 4
systray_background_id = 0
systray_icon_size = 20
systray_icon_asb = 100 0 0

# Clock: time on line one, date on line two
time1_format = %H:%M
time2_format = %a %d %b
time1_font = DejaVu Sans Bold 9
time2_font = DejaVu Sans 7
clock_font_color = #ffffff 100
clock_padding = 6 2
clock_background_id = 0
clock_tooltip = %A, %d %B %Y
clock_lclick_command = lxterminal -e date

# Tooltips and panel mouse behavior
tooltip_padding = 4 2
tooltip_show_timeout = 0.5
tooltip_hide_timeout = 0.1
mouse_middle = none
mouse_right = none
mouse_scroll_up = toggle
mouse_scroll_down = iconify
EOF

    retro_write /etc/skel/.config/jgmenu/jgmenurc 0644 <<'EOF'
position_mode = center
menu_width = 280
menu_height = 520
menu_padding = 8
menu_border = 1
menu_radius = 4
menu_halign = left
menu_valign = bottom
menu_margin_x = 0
menu_margin_y = 34
menu_font = DejaVu Sans 10
menu_icon_size = 24
color_menu_bg = #1b1d27 96
color_menu_border = #00ff9c 100
color_norm_bg = #1b1d27 0
color_norm_fg = #e0e0e0 100
color_sel_bg = #00ff9c 100
color_sel_fg = #0c0d12 100
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
    retro_info "Generating Openbox root menu for the X11 desktop"
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
    write_live_fixup
    write_menu_tools
    write_skel_session
    write_skel_theming
    generate_menus
    normalise_skel_permissions
    retro_ok "=== 02_interface_setup.sh: complete (Openbox + Tint2 + LXTerminal) ==="
}

main "$@"
