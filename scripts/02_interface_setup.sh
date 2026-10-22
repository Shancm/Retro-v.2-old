#!/usr/bin/env bash
# =============================================================================
# Retro OS v2.0 — 02_interface_setup.sh
# Runs INSIDE the debootstrap chroot as root.
# Installs the ~150-180MB GUI stack: Xorg + Openbox + Tint2 + PCManFM + Feh +
# Picom + LightDM (instant autologin into Openbox).
# =============================================================================
set -Eeuo pipefail

# Self-contained logging helpers
retro_info()  { echo -e "\033[0;36m[*] $*\033[0m"; }
retro_ok()    { echo -e "\033[0;32m[+] $*\033[0m"; }
retro_warn()  { echo -e "\033[0;33m[!] $*\033[0m"; }
retro_error() { echo -e "\033[0;31m[x] $*\033[0m"; }
retro_die()   { retro_error "$@"; exit 1; }

trap 'retro_error "01_engine_setup.sh failed at line ${LINENO} (exit ${?})"' ERR

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8

# Variables
DEBIAN_SUITE="bookworm"
DEBIAN_MIRROR="http://deb.debian.org/debian/"
DEBIAN_SECURITY_MIRROR="http://security.debian.org/debian-security"
DEBIAN_COMPONENTS="main contrib non-free non-free-firmware"
RETRO_OS_NAME="Retro OS"
RETRO_OS_VERSION="2.0"
RETRO_OS_EDITION="Tactical"
RETRO_OS_CODENAME="retro-os"
RETRO_USER="retro"
RETRO_USER_UID="1000"
RETRO_USER_PASS="retro"
RETRO_ROOT_PASS="retro"
RETRO_ROOT="/opt/retro-os"
RETRO_AI_DIR="/opt/retro-ai"
RETRO_ETC_DIR="/etc/retro-os"
RETRO_LOG_DIR="/var/log/retro-os"
RETRO_STATE_DIR="/var/lib/retro-os"
RETRO_BIN_DIR="/usr/local/bin"

# Dagitoy ti inayonmo ditoy:
RETRO_FONT_NAME="DejaVu Sans"
RETRO_BG_COLOR="#0C0D12"
RETRO_FG_COLOR="#D3D7CF"
RETRO_ACCENT_COLOR="#00FF9C"
RETRO_ICON_THEME="Papirus-Dark"

retro_info "[01] Configuring apt sources (${DEBIAN_SUITE}: ${DEBIAN_COMPONENTS})"

retro_info "[02] Installing Xorg + LXDE desktop stack"
apt-get install -y --no-install-recommends \
    xserver-xorg \
    xserver-xorg-video-all \
    xserver-xorg-input-all \
    xinit \
    x11-xserver-utils \
    lxde-core \
    lxterminal \
    xfce4-terminal \
    lightdm \
    lightdm-gtk-greeter \
    desktop-file-utils \
    papirus-icon-theme \
    arc-theme \
    lxappearance \
    vlc \
    pulseaudio \
    pavucontrol \
    volumeicon-alsa \
    firefox-esr \
    network-manager-gnome \
    udisks2 \
    pulseaudio-utils \
    xarchiver \
    zip \
    unzip \
    mousepad \
    galculator \
    net-tools \
    iproute2 \
    dnsutils \
    curl \
    wget \
    sudo

# -----------------------------------------------------------------------------
# 1. PATH Configuration (ifconfig പോലുള്ള കമാൻഡുകൾ റൺ ചെയ്യാൻ)
# -----------------------------------------------------------------------------
cat >> /etc/environment <<'EOF'
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF

cat >> /etc/skel/.bashrc <<'EOF'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
EOF

# -----------------------------------------------------------------------------
# LightDM: Instant Autologin → LXDE
# -----------------------------------------------------------------------------
retro_info "[02] Configuring LightDM autologin → LXDE"

# autologin ഗ്രൂപ്പ് ഉറപ്പാക്കുന്നു
groupadd -r autologin || true
gpasswd -a "${RETRO_USER}" autologin || true

install -d -m 755 /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-retro-autologin.conf <<EOF
[Seat:*]
autologin-user=${RETRO_USER}
autologin-user-timeout=0
autologin-session=LXDE
user-session=LXDE
greeter-session=lightdm-gtk-greeter
pam-service=lightdm-autologin
pam-autologin-service=lightdm-autologin
EOF

cat > /etc/lightdm/lightdm-gtk-greeter.conf <<EOF
[greeter]
theme-name = Arc-Dark
icon-theme-name = ${RETRO_ICON_THEME}
background = ${RETRO_BG_COLOR}
font-name = ${RETRO_FONT_NAME} 10
indicators = ~host;~spacer;~clock;~spacer;~session;~language;~power
EOF

retro_info "[02] Pre-seeding AccountsService for instant LXDE autologin"
install -d -m 755 /var/lib/AccountsService/users
cat > "/var/lib/AccountsService/users/${RETRO_USER}" <<EOF
[User]
Session=LXDE
Icon=/usr/share/pixmaps/retro-os-avatar.png
SystemAccount=false
EOF

# -----------------------------------------------------------------------------
# XFCE Terminal with Custom Background Image Setup
# -----------------------------------------------------------------------------
TERMINAL_SKEL="/etc/skel/.config/xfce4/terminal"
install -d -m 755 "${TERMINAL_SKEL}"

cat > "${TERMINAL_SKEL}/terminalrc" <<'EOF'
[Configuration]
FontName=DejaVu Sans Mono 10
ColorPalette=#000000;#cc0000;#4e9a06;#c4a000;#3465a4;#75507b;#06989a;#d3d7cf;#555753;#ef2929;#8ae234;#fce94f;#729fcf;#ad7fa8;#34e2e2;#eeeeec
ColorForeground=#00FF9C
ColorBackground=#0C0D12
ColorCursor=#00FF9C
TitleMode=TERMINAL_TITLE_REPLACE
MiscAlwaysShowTabs=FALSE
MiscBell=FALSE
MiscBordersDefault=TRUE
MiscCursorBlinks=TRUE
MiscCursorShape=TERMINAL_CURSOR_SHAPE_BLOCK
MiscDefaultGeometry=80x24
MiscInheritGeometry=FALSE
MiscMenubarDefault=FALSE
MiscMouseAutohide=FALSE
MiscToolbarDefault=FALSE
MiscConfirmClose=TRUE
MiscCycleTabs=TRUE
MiscTabCloseButtons=TRUE
MiscTabCloseMiddleClick=TRUE
MiscShowUnsafePasteDialog=FALSE
BackgroundMode=TERMINAL_BACKGROUND_IMAGE
BackgroundImageFile=/usr/share/backgrounds/retro-os/terminal-bg.png
BackgroundDarkness=0.85
EOF

# ഡെസ്ക്ടോപ്പ് ഡാറ്റാബേസും ഐക്കൺ കാഷെയും അപ്ഡേറ്റ് ചെയ്യുന്നു
update-desktop-database -q || true
gtk-update-icon-cache -f -t /usr/share/icons/Papirus-Dark || true
gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true

# skel പെർമിഷൻ കൃത്യമാക്കുന്നു
chmod -R 755 /etc/skel

retro_info "[02] Enabling display manager + NetworkManager services"
systemctl enable lightdm.service
systemctl enable NetworkManager.service
systemctl set-default graphical.target

retro_info "[02] Interface setup complete"
