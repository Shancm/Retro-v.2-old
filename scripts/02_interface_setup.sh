#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 — 02_interface_setup.sh
# Runs INSIDE the debootstrap chroot as root.
# Installs the ~150-180MB GUI stack: Xorg + Openbox + Tint2 + PCManFM + Feh +
# Picom + LightDM (instant autologin into Openbox).
# =============================================================================
set -Eeuo pipefail

# Sourcing config.env safely
if [ -f "/tmp/retro-build/config.env" ]; then
    source "/tmp/retro-build/config.env"
elif [ -f "./config.env" ]; then
    source "./config.env"
fi

trap 'retro_error "02_interface_setup.sh failed at line ${LINENO} (exit ${?})"' ERR

export DEBIAN_FRONTEND=noninteractive

retro_info "[02] Installing Xorg + Openbox desktop stack"
apt-get install -y --no-install-recommends \
    xserver-xorg \
    xserver-xorg-video-all \
    xserver-xorg-input-all \
    xinit \
    x11-xserver-utils \
    openbox \
    obconf \
    tint2 \
    pcmanfm \
    feh \
    picom \
    lightdm \
    lightdm-gtk-greeter \
    policykit-1 \
    polkitd \
    gvfs \
    gvfs-backends \
    xterm \
    lxterminal \
    fonts-dejavu \
    fonts-noto-color-emoji \
    papirus-icon-theme \
    arc-theme \
    lxappearance \
    network-manager-gnome \
    pavucontrol \
    pulseaudio \
    pulseaudio-utils \
    xarchiver \
    mousepad \
    scrot \
    galculator

# -----------------------------------------------------------------------------
# Openbox: system-wide default config (copied into each new user via /etc/skel)
# -----------------------------------------------------------------------------
retro_info "[02] Writing Openbox config (rc.xml, menu.xml, autostart)"

OB_SKEL="/etc/skel/.config/openbox"
install -d -m 755 "${OB_SKEL}"

cat > "${OB_SKEL}/autostart" <<'EOF'
#!/usr/bin/env bash
# Retro OS v2.0 — Openbox autostart
nitrogen --restore >/dev/null 2>&1 &
feh --bg-fill /usr/share/backgrounds/retro-os/wallpaper.png >/dev/null 2>&1 &
picom --config /etc/skel/.config/picom.conf -b >/dev/null 2>&1 &
pcmanfm --desktop --profile retro >/dev/null 2>&1 &
tint2 >/dev/null 2>&1 &
nm-applet >/dev/null 2>&1 &
/usr/local/bin/retro doctor --silent >/dev/null 2>&1 &
EOF
chmod 755 "${OB_SKEL}/autostart"

cat > "${OB_SKEL}/menu.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="Retro OS">
    <item label="Terminal"><action name="Execute"><command>lxterminal</command></action></item>
    <item label="File Manager"><action name="Execute"><command>pcmanfm</command></action></item>
    <item label="Text Editor"><action name="Execute"><command>mousepad</command></action></item>
    <item label="Calculator"><action name="Execute"><command>galculator</command></action></item>
    <separator/>
    <menu id="retro-ai" label="Retro / Bujji AI">
      <item label="Talk to Bujji"><action name="Execute"><command>lxterminal -e retro bujji</command></action></item>
      <item label="System Doctor"><action name="Execute"><command>lxterminal -e retro doctor</command></action></item>
      <item label="Ghost Mode (anonymity)"><action name="Execute"><command>lxterminal -e retro ghost</command></action></item>
      <item label="Kali Toolbox (Distrobox)"><action name="Execute"><command>lxterminal -e retro kali</command></action></item>
    </menu>
    <menu id="security-tools" label="Security Tools">
      <item label="Wireshark"><action name="Execute"><command>wireshark</command></action></item>
      <item label="nmap (terminal)"><action name="Execute"><command>lxterminal -e sudo nmap</command></action></item>
      <item label="Aircrack-ng Suite"><action name="Execute"><command>lxterminal -e sudo bash -lc 'airmon-ng; bash'</command></action></item>
      <item label="Hashcat"><action name="Execute"><command>lxterminal -e hashcat --help</command></action></item>
      <item label="John the Ripper"><action name="Execute"><command>lxterminal -e john --help</command></action></item>
      <item label="Hydra"><action name="Execute"><command>lxterminal -e hydra -h</command></action></item>
      <item label="Nikto"><action name="Execute"><command>lxterminal -e nikto -Help</command></action></item>
      <item label="SQLmap"><action name="Execute"><command>lxterminal -e sqlmap --wizard</command></action></item>
      <item label="Dirb"><action name="Execute"><command>lxterminal -e dirb</command></action></item>
    </menu>
    <menu id="system-menu" label="System">
      <item label="Appearance (lxappearance)"><action name="Execute"><command>lxappearance</command></action></item>
      <item label="Openbox Config (obconf)"><action name="Execute"><command>obconf</command></action></item>
      <item label="Network Connections"><action name="Execute"><command>nm-connection-editor</command></action></item>
      <item label="Volume Control"><action name="Execute"><command>pavucontrol</command></action></item>
      <item label="Reconfigure Openbox"><action name="Reconfigure"/></item>
    </menu>
    <separator/>
    <item label="Lock Screen"><action name="Execute"><command>xterm -e "echo locking not configured"</command></action></item>
    <item label="Log Out"><action name="Exit"><prompt>yes</prompt></action></item>
    <item label="Shutdown"><action name="Execute"><command>systemctl poweroff</command></action></item>
    <item label="Reboot"><action name="Execute"><command>systemctl reboot</command></action></item>
  </menu>
</openbox_menu>
EOF

cat > "${OB_SKEL}/rc.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <resistance><strength>10</strength><screen_edge_strength>20</screen_edge_strength></resistance>
  <focus><focusNew>yes</focusNew><followMouse>no</followMouse></focus>
  <theme>
    <name>Arc-Dark</name>
    <titleLayout>NLIMC</titleLayout>
    <keepBorder>yes</keepBorder>
    <font place="ActiveWindow"><name>${RETRO_FONT_NAME}</name><size>9</size><weight>Bold</weight></font>
    <font place="InactiveWindow"><name>${RETRO_FONT_NAME}</name><size>9</size></font>
  </theme>
  <desktops><number>4</number><names><name>Main</name><name>Net</name><name>Tools</name><name>Scratch</name></names></desktops>
  <keyboard>
    <keybind key="W-Return"><action name="Execute"><command>lxterminal</command></action></keybind>
    <keybind key="W-e"><action name="Execute"><command>pcmanfm</command></action></keybind>
    <keybind key="W-d"><action name="ToggleShowDesktop"/></keybind>
    <keybind key="A-F4"><action name="Close"/></keybind>
    <keybind key="A-Tab"><action name="NextWindow"/></keybind>
  </keyboard>
  <mouse>
    <context name="Root">
      <mousebind button="Right" action="Press"><action name="ShowMenu"><menu>root-menu</menu></action></mousebind>
    </context>
  </mouse>
  <menu><file>menu.xml</file><hideDelay>200</hideDelay><middle>no</middle><submenuShowDelay>100</submenuShowDelay></menu>
</openbox_config>
EOF

# -----------------------------------------------------------------------------
# Tint2 panel
# -----------------------------------------------------------------------------
TINT2_SKEL="/etc/skel/.config/tint2"
install -d -m 755 "${TINT2_SKEL}"
cat > "${TINT2_SKEL}/tint2rc" <<EOF
# Retro OS v2.0 tint2 panel
panel_items = TSC
panel_size = 100% 28
panel_position = bottom center horizontal
panel_background_id = 1
rounded = 0
background_color = ${RETRO_BG_COLOR} 92

taskbar_mode = single_desktop
task_text = 1
task_font = ${RETRO_FONT_NAME} 9
task_font_color = ${RETRO_FG_COLOR} 100
task_active_font_color = ${RETRO_ACCENT_COLOR} 100

systray_padding = 4 4 4
systray_icon_size = 18

clock_font = ${RETRO_FONT_NAME} 9
clock_font_color = ${RETRO_ACCENT_COLOR} 100
time1_format = %H:%M
time2_format = %a %d %b
clock_rclick_command = retro doctor
EOF

# -----------------------------------------------------------------------------
# Picom (compositor) — light config for low-end GPUs
# -----------------------------------------------------------------------------
cat > "/etc/skel/.config/picom.conf" <<'EOF'
backend = "xrender";
vsync = false;
shadow = false;
fading = true;
fade-in-step = 0.06;
fade-out-step = 0.06;
corner-radius = 0;
blur-background = false;
EOF

# -----------------------------------------------------------------------------
# PCManFM desktop/wallpaper profile
# -----------------------------------------------------------------------------
install -d -m 755 "/etc/skel/.config/pcmanfm/retro"
cat > "/etc/skel/.config/pcmanfm/retro/desktop-items-0.conf" <<EOF
[*]
wallpaper_mode=fit
wallpaper=/usr/share/backgrounds/retro-os/wallpaper.png
desktop_bg=${RETRO_BG_COLOR}
desktop_fg=${RETRO_FG_COLOR}
desktop_shadow=${RETRO_BG_COLOR}
desktop_font=${RETRO_FONT_NAME} 9
show_documents=0
show_trash=1
show_mounts=1
EOF
install -d -m 755 "/etc/skel/.config/pcmanfm/retro"
cat > "/etc/skel/.config/pcmanfm/retro/pcmanfm.conf" <<'EOF'
[config]
bm_open_method=0
[volume]
mount_on_startup=1
mount_removable=1
autorun=0
EOF

# -----------------------------------------------------------------------------
# Wallpaper placeholder (generated, not a copyrighted asset)
# -----------------------------------------------------------------------------
install -d -m 755 /usr/share/backgrounds/retro-os
if is_command convert; then
    convert -size 1920x1080 "xc:${RETRO_BG_COLOR}" \
        -fill "${RETRO_ACCENT_COLOR}" -gravity center \
        -pointsize 64 -annotate 0 "RETRO OS v${RETRO_OS_VERSION}" \
        /usr/share/backgrounds/retro-os/wallpaper.png 2>/dev/null || \
    printf '' > /usr/share/backgrounds/retro-os/wallpaper.png
else
    printf '' > /usr/share/backgrounds/retro-os/wallpaper.png
fi

# -----------------------------------------------------------------------------
# LightDM: instant automatic login into Openbox, no greeter delay
# -----------------------------------------------------------------------------
retro_info "[02] Configuring LightDM autologin → Openbox"

install -d -m 755 /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-retro-autologin.conf <<EOF
[Seat:*]
autologin-user=${RETRO_USER}
autologin-user-timeout=0
autologin-session=openbox
user-session=openbox
greeter-session=lightdm-gtk-greeter
EOF

cat > /etc/lightdm/lightdm-gtk-greeter.conf <<EOF
[greeter]
theme-name = Arc-Dark
icon-theme-name = ${RETRO_ICON_THEME}
background = ${RETRO_BG_COLOR}
font-name = ${RETRO_FONT_NAME} 10
indicators = ~host;~spacer;~clock;~spacer;~session;~language;~power
EOF

# Make sure an "openbox" session entry exists for the greeter/autologin to pick up
cat > /usr/share/xsessions/openbox.desktop <<'EOF'
[Desktop Entry]
Name=Openbox (Retro OS)
Comment=Lightweight Openbox session
Exec=openbox-session
Type=Application
EOF

retro_info "[02] Pre-seeding PAM/AccountsService for zero-prompt autologin"
# AccountsService hint used by lightdm-gtk-greeter so it never pauses
# expecting a manual click; the actual password-less auth is handled by
# LightDM's own autologin path above (pam_succeed_if / pam_unix is left
# intact for console/TTY logins — only the display-manager autologin
# path bypasses interactive prompting).
install -d -m 755 /var/lib/AccountsService/users
cat > "/var/lib/AccountsService/users/${RETRO_USER}" <<EOF
[User]
Session=openbox
Icon=/usr/share/pixmaps/retro-os-avatar.png
SystemAccount=false
EOF

retro_info "[02] Enabling display manager + NetworkManager services"
systemctl enable lightdm.service
systemctl enable NetworkManager.service
systemctl set-default graphical.target

retro_info "[02] Interface setup complete"
