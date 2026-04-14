#!/usr/bin/env bash
# =============================================================================
#  ____  _     _               ____  _
# |  _ \(_)___| |_ _ __ ___  |  _ \| | ___  _ __  _ __   ___ _ __
# | | | | / __| __| '__/ _ \ | |_) | |/ _ \| '_ \| '_ \ / _ \ '__|
# | |_| | \__ \ |_| | | (_) ||  __/| | (_) | |_) | |_) |  __/ |
# |____/|_|___/\__|_|  \___/ |_|   |_|\___/| .__/| .__/ \___|_|
#                                           |_|   |_|
#
# distro-plopper — Export your Linux desktop setup. Plop it onto a new distro.
#
# MIT License
# Copyright (c) 2026 Rob Brown
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# ─────────────────────────────────────────────────────────────────────────────
# ⚠️  DISCLAIMER — READ THIS
# ─────────────────────────────────────────────────────────────────────────────
# This script is provided as-is, unsupported, and unmaintained.
# No warranty is given. No support is offered. You run this entirely at
# your own risk. The author accepts zero responsibility for data loss,
# system damage, corrupted configs, existential dread, or any other outcome
# resulting from use of this script.
#
# This is a hobby tool. Test it. Read what it does before you run it.
# Back up your data independently before doing anything irreversible.
# ─────────────────────────────────────────────────────────────────────────────
#
# USAGE:
#   bash distro-plopper.sh --export [OPTIONS]
#   bash distro-plopper.sh --import --bundle /path/to/bundle [OPTIONS]
#
# EXPORT OPTIONS:
#   --dry-run             Scan and report only, copy nothing
#   --skip-browsers       Skip browser profile backup
#   --skip-flatpak-data   Skip ~/.var/app data
#   --skip-steam          Skip all Steam data
#   --skip-homedirs       Skip XDG home directories (Documents, Downloads, etc.)
#   --skip-userhomes      Skip /home/* user directory export
#   --no-archive          Skip .tar.gz creation (bundle directory only)
#   --output DIR          Output directory (default: ~/distro-plopper-TIMESTAMP)
#
# IMPORT OPTIONS:
#   --bundle PATH         Path to export bundle dir or .tar.gz archive (required)
#   --output DIR          Directory for import log and extracted archive (default: same dir as bundle)
#   --no-packages         Skip package installation
#   --no-configs          Skip config/dotfile restore
#   --no-gnome            Skip GNOME/dconf restore
#   --no-flatpak          Skip Flatpak data restore
#   --no-browsers         Skip browser profile restore
#   --no-fonts            Skip font restore
#   --no-ssh              Skip SSH config restore
#   --no-steam            Skip Steam config restore
#   --no-cups             Skip CUPS printer restore
#   --no-displaycal       Skip DisplayCAL/ArgyllCMS profile restore
#   --no-turboprint       Skip TurboPrint config restore
#   --no-homedirs         Skip XDG home directory restore
#   --no-userhomes        Skip /home/* user directory restore
#   --dry-run             Show what would be done, do nothing
#
# EXAMPLES:
#   bash distro-plopper.sh --export
#   bash distro-plopper.sh --export --output /mnt/usb/my-backup
#   bash distro-plopper.sh --export --dry-run --skip-steam
#   bash distro-plopper.sh --import --bundle ~/distro-plopper-20250101_120000
#   bash distro-plopper.sh --import --bundle ~/distro-plopper-20250101_120000.tar.gz
#   bash distro-plopper.sh --import --bundle ~/bundle --output /tmp/plopper-import
#   bash distro-plopper.sh --import --bundle ~/bundle --no-packages --dry-run
#
# =============================================================================

set -euo pipefail

# ── Keep terminal open if launched from a file manager ────────────────────────
# Nautilus/Nemo/Thunar open a terminal that closes the instant the script exits.
# Detect this by checking if our parent is a file manager or if no args were
# passed (double-click launch), and pause before exit so the user can read output.
_LAUNCHED_FROM_FM=false
if [[ $# -eq 0 ]]; then
    _LAUNCHED_FROM_FM=true
fi
_pause_if_fm() {
    if [[ "$_LAUNCHED_FROM_FM" == true ]]; then
        echo ""
        read -rp "  Press Enter to close..." _DUMMY || true
    fi
}
trap _pause_if_fm EXIT


# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()     { echo -e "${RED}[ERR]${RESET}   $*" >&2; }
header()  { echo -e "\n${BOLD}━━━ $* ━━━${RESET}"; }
step()    { echo -e "\n${BOLD}  ► $*${RESET}"; }

# ── Distro detection ─────────────────────────────────────────────────────────
# Sets PKG_MANAGER, PKG_INSTALL, PKG_QUERY, PKG_QUERY_EXPLICIT, PKG_FAMILY
# so all package operations below are distro-agnostic.
detect_distro() {
    PKG_FAMILY="unknown"
    PKG_MANAGER="unknown"
    PKG_INSTALL=""
    PKG_QUERY_EXPLICIT=""   # list explicitly installed packages
    PKG_QUERY_NATIVE=""     # list from official repos only
    PKG_QUERY_FOREIGN=""    # list AUR/PPA/COPR/OBS etc.
    AUR_HELPER=""

    if command -v pacman &>/dev/null; then
        PKG_FAMILY="arch"
        PKG_MANAGER="pacman"
        PKG_QUERY_EXPLICIT="pacman -Qqe"
        PKG_QUERY_NATIVE="pacman -Qqen"
        PKG_QUERY_FOREIGN="pacman -Qqem"
        PKG_INSTALL="sudo pacman -S --needed --noconfirm"
        command -v yay  &>/dev/null && AUR_HELPER="yay"  || true
        command -v paru &>/dev/null && AUR_HELPER="paru" || true

    elif command -v dnf &>/dev/null; then
        PKG_FAMILY="fedora"
        PKG_MANAGER="dnf"
        # dnf: user-installed = reason=user, exclude groups/kernel noise
        PKG_QUERY_EXPLICIT="dnf repoquery --userinstalled --queryformat '%{name}' 2>/dev/null"
        PKG_QUERY_NATIVE="$PKG_QUERY_EXPLICIT"
        PKG_QUERY_FOREIGN="dnf repoquery --userinstalled --queryformat '%{name}' --repo=* 2>/dev/null | grep -v $(dnf repolist --quiet | awk '{print $1}' | grep -v 'repo' | paste -sd'|')"
        PKG_INSTALL="sudo dnf install -y"

    elif command -v apt &>/dev/null; then
        PKG_FAMILY="debian"
        PKG_MANAGER="apt"
        # Detect Ubuntu vs pure Debian
        if grep -qiE "ubuntu|linuxmint|pop.os|elementary|zorin|kubuntu|xubuntu|lubuntu" /etc/os-release 2>/dev/null; then
            PKG_SUBFAMILY="ubuntu"
        else
            PKG_SUBFAMILY="debian"
        fi
        # apt-mark showmanual is the most reliable way to list user-installed packages
        PKG_QUERY_EXPLICIT="apt-mark showmanual 2>/dev/null | sort"
        PKG_QUERY_NATIVE="apt-mark showmanual 2>/dev/null | sort"
        PKG_QUERY_FOREIGN=""   # Ubuntu/Debian foreign handled in scan block
        PKG_INSTALL="sudo apt install -y"

    elif command -v zypper &>/dev/null; then
        PKG_FAMILY="suse"
        PKG_MANAGER="zypper"
        PKG_QUERY_EXPLICIT="zypper search --installed-only -t package 2>/dev/null | awk -F'|' 'NR>4 {gsub(/ /,\"\",\$3); print \$3}'"
        PKG_QUERY_NATIVE="$PKG_QUERY_EXPLICIT"
        PKG_QUERY_FOREIGN=""
        PKG_INSTALL="sudo zypper install -y"

    elif command -v emerge &>/dev/null; then
        PKG_FAMILY="gentoo"
        PKG_MANAGER="emerge"
        PKG_QUERY_EXPLICIT="qlist -IRv 2>/dev/null"
        PKG_QUERY_NATIVE="$PKG_QUERY_EXPLICIT"
        PKG_QUERY_FOREIGN=""
        PKG_INSTALL="sudo emerge"
    fi
}
detect_distro

# ── Whiptail check — offer to install if missing ──────────────────────────────
if ! command -v whiptail &>/dev/null; then
    echo ""
    echo -e "${YELLOW}[WARN]${RESET}  whiptail is not installed."
    echo    "        It provides the interactive menus for distro-plopper."
    echo    "        Without it the script falls back to plain text prompts."
    echo ""
    read -rp "        Install whiptail now? [Y/n] " _WT_CONFIRM
    if [[ "${_WT_CONFIRM,,}" != "n" ]]; then
        echo ""
        case "$PKG_FAMILY" in
            arch)    sudo pacman -S --noconfirm whiptail 2>/dev/null \
                     || sudo pacman -S --noconfirm libnewt ;;
            fedora)  sudo dnf install -y newt ;;
            debian)  sudo apt install -y whiptail ;;
            suse)    sudo zypper install -y whiptail ;;
            gentoo)  sudo emerge -av newt ;;
            *)       echo -e "${YELLOW}[WARN]${RESET}  Unknown distro — install whiptail manually and re-run." ;;
        esac
        if command -v whiptail &>/dev/null; then
            echo -e "${GREEN}[OK]${RESET}    whiptail installed successfully."
        else
            echo -e "${YELLOW}[WARN]${RESET}  whiptail install failed — continuing in text mode."
        fi
    else
        echo -e "        ${YELLOW}Continuing in text-only mode.${RESET}"
    fi
    echo ""
fi

# ── Distro-aware package file names ──────────────────────────────────────────
# Export saves to these; import reads from these.
# On Arch: native=pacman-native.txt, foreign=pacman-aur.txt
# On others: native=<mgr>-packages.txt, foreign=<mgr>-foreign.txt
PKG_NATIVE_FILE="${PKG_MANAGER}-native.txt"
PKG_FOREIGN_FILE="${PKG_MANAGER}-foreign.txt"
PKG_EXPLICIT_FILE="${PKG_MANAGER}-explicit.txt"
PKG_SUBFAMILY="${PKG_SUBFAMILY:-}"   # ubuntu | debian | (empty for non-apt)

# ── Defaults ──────────────────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MODE=""
DRY_RUN=false

# Export flags
OUTPUT_DIR="$HOME/distro-plopper-$TIMESTAMP"
SKIP_BROWSERS=false
SKIP_FLATPAK_DATA=false
SKIP_STEAM=false
SKIP_HOMEDIRS=false
SKIP_USERHOMES=false
# Initialised here so they are always bound regardless of TUI/non-TUI path
ARCHIVE=""
ARCHIVE_CHOICE="yes"
ARCHIVE_SIZE="n/a"
EXP_PACKAGES=true
EXP_CONFIGS=true
EXP_DOTFILES=true
EXP_LOCALSHARE=true
EXP_GNOME=true
EXP_SSH=true
EXP_FONTS=true
EXP_NFS=true
EXP_SYSTEMD=true
EXP_DOCKER=true
EXP_HARDWARE=true
EXP_FLATPAKDATA=true
EXP_BROWSERS=true
EXP_STEAM=true
EXP_TURBOPRINT=true
EXP_CUPS=true
EXP_DISPLAYCAL=true
EXP_HOMEDIRS=false
EXP_USERHOMES=false

# Import flags
BUNDLE_PATH=""
IMPORT_OUTPUT_DIR=""   # defaults to same directory as bundle, set via --output on import
IMP_NO_PACKAGES=false
IMP_NO_CONFIGS=false
IMP_NO_GNOME=false
IMP_NO_FLATPAK=false
IMP_NO_BROWSERS=false
IMP_NO_FONTS=false
IMP_NO_SSH=false
IMP_NO_STEAM=false
IMP_NO_CUPS=false
IMP_NO_DISPLAYCAL=false
IMP_NO_TURBOPRINT=false
IMP_NO_HOMEDIRS=false
IMP_NO_USERHOMES=false

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --export)            MODE="export" ;;
        --import)            MODE="import" ;;
        --dry-run)           DRY_RUN=true ;;
        # export options
        --skip-browsers)     SKIP_BROWSERS=true ;;
        --skip-flatpak-data) SKIP_FLATPAK_DATA=true ;;
        --skip-steam)        SKIP_STEAM=true ;;
        --skip-homedirs)     SKIP_HOMEDIRS=true ;;
        --skip-userhomes)    SKIP_USERHOMES=true ;;
        --no-archive)        ARCHIVE_CHOICE="no" ;;
        --output)            OUTPUT_DIR="$2"; IMPORT_OUTPUT_DIR="$2"; shift ;;
        # import options
        --bundle)            BUNDLE_PATH="$2"; shift ;;
        --no-packages)       IMP_NO_PACKAGES=true ;;
        --no-configs)        IMP_NO_CONFIGS=true ;;
        --no-gnome)          IMP_NO_GNOME=true ;;
        --no-flatpak)        IMP_NO_FLATPAK=true ;;
        --no-browsers)       IMP_NO_BROWSERS=true ;;
        --no-fonts)          IMP_NO_FONTS=true ;;
        --no-ssh)            IMP_NO_SSH=true ;;
        --no-steam)          IMP_NO_STEAM=true ;;
        --no-cups)           IMP_NO_CUPS=true ;;
        --no-displaycal)     IMP_NO_DISPLAYCAL=true ;;
        --no-turboprint)     IMP_NO_TURBOPRINT=true ;;
        --no-homedirs)       IMP_NO_HOMEDIRS=true ;;
        --no-userhomes)      IMP_NO_USERHOMES=true ;;
        --help|-h)
            grep "^# " "$0" | sed 's/^# \{0,2\}//' | head -60
            exit 0 ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

if [[ -z "$MODE" ]]; then
    if command -v whiptail &>/dev/null; then
        TERM_H=$(tput lines); TERM_W=$(tput cols)
        BOX_H=$(( TERM_H - 4 )); BOX_W=$(( TERM_W - 8 ))
        [[ $BOX_H -lt 20 ]] && BOX_H=20
        [[ $BOX_W -lt 70 ]] && BOX_W=70

        MODE_CHOICE=$(whiptail --title "🪣  Distro Plopper" \
          --menu \
"Welcome to Distro Plopper!

What would you like to do?

  EXPORT  —  Scan this system and save everything to a
             bundle you can carry to a new machine.

  IMPORT  —  Take a bundle from a previous export and
             restore packages, configs, and data onto
             this system." \
          $BOX_H $BOX_W 3 \
          "export" "Export — back up this system" \
          "import" "Import — restore from a bundle" \
          "help"   "Show help and exit" \
          3>&1 1>&2 2>&3) || { echo "Cancelled."; exit 0; }

        case "$MODE_CHOICE" in
            export) MODE="export" ;;
            import)
                MODE="import"
                BUNDLE_PATH=$(whiptail --title "Import — Bundle Path" \
                  --inputbox \
"Enter the path to your distro-plopper export bundle.
This can be a directory or a .tar.gz archive.

Examples:
  /home/$USER/distro-plopper-20250101_120000
  /mnt/usb/distro-plopper-20250101_120000.tar.gz" \
                  12 $BOX_W "" \
                  3>&1 1>&2 2>&3) || { echo "Cancelled."; exit 0; }

                if [[ -z "$BUNDLE_PATH" ]]; then
                    whiptail --title "Error" --msgbox "No bundle path entered." 8 $BOX_W
                    exit 1
                fi
                ;;
            help)
                grep "^# " "$0" | sed 's/^# \{0,2\}//' | head -60
                exit 0
                ;;
        esac
    else
        # No whiptail — fall back to simple text prompt
        echo ""
        echo -e "${BOLD}  🪣  Distro Plopper${RESET}"
        echo ""
        echo "  What would you like to do?"
        echo "    1) Export — back up this system"
        echo "    2) Import — restore from a bundle"
        echo "    3) Help"
        echo ""
        read -rp "  Enter choice [1/2/3]: " _CHOICE
        case "$_CHOICE" in
            1) MODE="export" ;;
            2)
                MODE="import"
                echo ""
                read -rp "  Path to bundle (dir or .tar.gz): " BUNDLE_PATH
                [[ -z "$BUNDLE_PATH" ]] && { err "No bundle path given."; exit 1; }
                ;;
            3)
                grep "^# " "$0" | sed 's/^# \{0,2\}//' | head -60
                exit 0
                ;;
            *)
                err "Invalid choice."
                exit 1
                ;;
        esac
    fi
fi

# =============================================================================
# ███████╗██╗  ██╗██████╗  ██████╗ ██████╗ ████████╗
# ██╔════╝╚██╗██╔╝██╔══██╗██╔═══██╗██╔══██╗╚══██╔══╝
# █████╗   ╚███╔╝ ██████╔╝██║   ██║██████╔╝   ██║
# ██╔══╝   ██╔██╗ ██╔═══╝ ██║   ██║██╔══██╗   ██║
# ███████╗██╔╝ ██╗██║     ╚██████╔╝██║  ██║   ██║
# ╚══════╝╚═╝  ╚═╝╚═╝      ╚═════╝ ╚═╝  ╚═╝   ╚═╝
# =============================================================================
if [[ "$MODE" == "export" ]]; then

# ── Scan state ────────────────────────────────────────────────────────────────
declare -A SCAN_RESULTS
declare -a WARNINGS=()

# =============================================================================
# PHASE 1: SYSTEM-WIDE SCAN
# =============================================================================
header "PHASE 1: Scanning system..."

SCAN_TMP=$(mktemp -d)
trap '_pause_if_fm; rm -rf "$SCAN_TMP"' EXIT

# S1. Packages
info "Scanning packages (${PKG_MANAGER})..."
> "$SCAN_TMP/apps.txt"
> "$SCAN_TMP/cli-tools.txt"

if [[ "$PKG_MANAGER" != "unknown" ]]; then
    # Build full explicit list
    _EXPLICIT_TMP=$(mktemp)
    eval "$PKG_QUERY_EXPLICIT" > "$_EXPLICIT_TMP" 2>/dev/null || true

    # Find packages that own a .desktop file — these are the "apps"
    _DESKTOP_OWNERS=$(mktemp)
    case "$PKG_FAMILY" in
        arch)
            pacman -Qqo /usr/share/applications/*.desktop 2>/dev/null \
                | sort -u > "$_DESKTOP_OWNERS" || true
            ;;
        fedora)
            rpm -qf /usr/share/applications/*.desktop 2>/dev/null \
                | grep -v "not owned" | sed 's/-[0-9].*//' \
                | sort -u > "$_DESKTOP_OWNERS" || true
            ;;
        debian)
            dpkg -S /usr/share/applications/*.desktop 2>/dev/null \
                | cut -d: -f1 | sort -u > "$_DESKTOP_OWNERS" || true
            ;;
        suse)
            rpm -qf /usr/share/applications/*.desktop 2>/dev/null \
                | grep -v "not owned" | sed 's/-[0-9].*//' \
                | sort -u > "$_DESKTOP_OWNERS" || true
            ;;
    esac

    # apps = explicitly installed AND owns a .desktop (excludes dep-only packages)
    comm -12 <(sort "$_EXPLICIT_TMP") <(sort "$_DESKTOP_OWNERS") \
        > "$SCAN_TMP/apps.txt" || true
    # CLI tools = explicitly installed but no .desktop file
    comm -23 <(sort "$_EXPLICIT_TMP") <(sort "$_DESKTOP_OWNERS") \
        > "$SCAN_TMP/cli-tools.txt" || true
    rm -f "$_DESKTOP_OWNERS"

    SCAN_RESULTS[pacman_apps]=$(wc -l < "$SCAN_TMP/apps.txt")
    SCAN_RESULTS[pacman_cli]=$(wc -l < "$SCAN_TMP/cli-tools.txt")
    SCAN_RESULTS[pacman_total]=$(( SCAN_RESULTS[pacman_apps] + SCAN_RESULTS[pacman_cli] ))
    rm -f "$_EXPLICIT_TMP"
    ok "${PKG_MANAGER}: ${SCAN_RESULTS[pacman_apps]} apps, ${SCAN_RESULTS[pacman_cli]} CLI tools"
else
    WARNINGS+=("No supported package manager found (tried pacman/dnf/apt/zypper/emerge)")
    SCAN_RESULTS[pacman_total]=0; SCAN_RESULTS[pacman_apps]=0; SCAN_RESULTS[pacman_cli]=0
fi

# S2. Flatpak
info "Scanning Flatpak..."
touch "$SCAN_TMP/flatpak-apps.txt" "$SCAN_TMP/flatpak-full.txt" "$SCAN_TMP/flatpak-data-dirs.txt"
if command -v flatpak &>/dev/null; then
    flatpak list --app --columns=application > "$SCAN_TMP/flatpak-apps.txt"
    flatpak list --app --columns=application,name,version,origin > "$SCAN_TMP/flatpak-full.txt"
    SCAN_RESULTS[flatpak_count]=$(wc -l < "$SCAN_TMP/flatpak-apps.txt")
    while read -r app; do
        for subdir in config data cache; do
            D="$HOME/.var/app/$app/$subdir"
            [[ -d "$D" ]] && echo "$D" >> "$SCAN_TMP/flatpak-data-dirs.txt"
        done
    done < "$SCAN_TMP/flatpak-apps.txt"
    SCAN_RESULTS[flatpak_data_size]=$(du -sh "$HOME/.var/app" 2>/dev/null | awk '{print $1}' || echo "?")
    ok "Flatpak: ${SCAN_RESULTS[flatpak_count]} apps, ~/.var/app: ${SCAN_RESULTS[flatpak_data_size]}"
    [[ "$SKIP_FLATPAK_DATA" == true ]] && warn "Flatpak data copy SKIPPED (--skip-flatpak-data)"
else
    SCAN_RESULTS[flatpak_count]=0; SCAN_RESULTS[flatpak_data_size]="n/a"
    warn "Flatpak not installed"
fi

# S3. AppImages
info "Scanning for AppImages..."
find "$HOME" /opt /usr/local/bin /usr/local/lib 2>/dev/null \
    \( -name "*.AppImage" -o -name "*.appimage" \) \
    -not -path "*/proc/*" -not -path "*/sys/*" \
    | sort -u > "$SCAN_TMP/appimages.txt" || true
SCAN_RESULTS[appimage_count]=$(wc -l < "$SCAN_TMP/appimages.txt")
ok "AppImages: ${SCAN_RESULTS[appimage_count]} found"

# S4. ~/.config full scan
info "Scanning ~/.config (full)..."
find "$HOME/.config" -mindepth 1 -maxdepth 1 -type d | sort > "$SCAN_TMP/config-dirs.txt"
find "$HOME/.config" -mindepth 1 -maxdepth 1 -type f | sort > "$SCAN_TMP/config-files.txt"
SCAN_RESULTS[config_dir_count]=$(wc -l < "$SCAN_TMP/config-dirs.txt")
SCAN_RESULTS[config_size]=$(du -sh "$HOME/.config" 2>/dev/null | awk '{print $1}' || echo "?")
ok "~/.config: ${SCAN_RESULTS[config_dir_count]} dirs, size: ${SCAN_RESULTS[config_size]}"

# S5. ~/.local/share full scan
info "Scanning ~/.local/share..."
find "$HOME/.local/share" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort > "$SCAN_TMP/local-share-dirs.txt"
SCAN_RESULTS[local_share_size]=$(du -sh "$HOME/.local/share" 2>/dev/null | tail -1 | awk '{print $1}' | grep -v '^$' || echo '?')
ok "~/.local/share: $(wc -l < "$SCAN_TMP/local-share-dirs.txt") dirs, size: ${SCAN_RESULTS[local_share_size]}"

# S6. Home dotfiles
info "Scanning home dotfiles..."
find "$HOME" -maxdepth 1 -name ".*" \
    -not -name ".." -not -name ".cache" -not -name ".var" \
    -not -name ".local" -not -name ".config" \
    -not -name ".dbus" -not -name ".gvfs" \
    2>/dev/null | sort > "$SCAN_TMP/home-dotfiles.txt"
SCAN_RESULTS[dotfile_count]=$(wc -l < "$SCAN_TMP/home-dotfiles.txt")
ok "Home dotfiles: ${SCAN_RESULTS[dotfile_count]} found"

# S7. Browsers
info "Scanning browser profiles..."
> "$SCAN_TMP/browser-profiles.txt"
BROWSER_DIRS=(
    "$HOME/.mozilla:Firefox"
    "$HOME/.config/chromium:Chromium"
    "$HOME/.config/google-chrome:Google Chrome"
    "$HOME/.config/brave:Brave"
    "$HOME/.config/BraveSoftware/Brave-Browser:Brave (alt)"
    "$HOME/.config/microsoft-edge:Edge"
    "$HOME/.config/vivaldi:Vivaldi"
    "$HOME/.config/opera:Opera"
    "$HOME/.config/librewolf:LibreWolf"
    "$HOME/.config/falkon:Falkon"
    "$HOME/.config/qutebrowser:qutebrowser"
    "$HOME/.config/thorium-browser:Thorium"
    "$HOME/.config/waterfox:Waterfox"
    "$HOME/.var/app/org.mozilla.firefox:Firefox (Flatpak)"
    "$HOME/.var/app/com.google.Chrome:Chrome (Flatpak)"
    "$HOME/.var/app/com.brave.Browser:Brave (Flatpak)"
    "$HOME/.var/app/io.gitlab.librewolf-community.LibreWolf:LibreWolf (Flatpak)"
)
for entry in "${BROWSER_DIRS[@]}"; do
    DIR="${entry%%:*}"; NAME="${entry##*:}"
    if [[ -d "$DIR" ]]; then
        SIZE=$(du -sh "$DIR" 2>/dev/null | tail -1 | awk '{print $1}' | tr -d '\n\r' || echo "?")
        echo "$NAME|$DIR|$SIZE" >> "$SCAN_TMP/browser-profiles.txt"
        ok "Browser: $NAME ($SIZE)"
    fi
done
[[ "$SKIP_BROWSERS" == true ]] && warn "Browser copy SKIPPED (--skip-browsers)"

# S8. GNOME
info "Scanning GNOME..."
touch "$SCAN_TMP/gnome-extensions-all.txt" "$SCAN_TMP/gnome-extensions-enabled.txt" "$SCAN_TMP/dconf-full.ini"
if command -v gnome-extensions &>/dev/null; then
    gnome-extensions list > "$SCAN_TMP/gnome-extensions-all.txt" 2>/dev/null || true
    gnome-extensions list --enabled > "$SCAN_TMP/gnome-extensions-enabled.txt" 2>/dev/null || true
    SCAN_RESULTS[gnome_ext_count]=$(wc -l < "$SCAN_TMP/gnome-extensions-all.txt")
    ok "GNOME extensions: ${SCAN_RESULTS[gnome_ext_count]}"
else
    SCAN_RESULTS[gnome_ext_count]=0
fi
if command -v dconf &>/dev/null; then
    dconf dump / > "$SCAN_TMP/dconf-full.ini" 2>/dev/null || true
    SCAN_RESULTS[dconf_lines]=$(wc -l < "$SCAN_TMP/dconf-full.ini")
    ok "dconf: ${SCAN_RESULTS[dconf_lines]} lines"
else
    SCAN_RESULTS[dconf_lines]=0
fi

# S9. Fonts
info "Scanning fonts..."
> "$SCAN_TMP/fonts.txt"
for FDIR in "$HOME/.local/share/fonts" "$HOME/.fonts"; do
    [[ -d "$FDIR" ]] && find "$FDIR" -type f \( -name "*.ttf" -o -name "*.otf" -o -name "*.woff2" -o -name "*.woff" \) >> "$SCAN_TMP/fonts.txt" || true
done
SCAN_RESULTS[font_count]=$(wc -l < "$SCAN_TMP/fonts.txt")
ok "Fonts: ${SCAN_RESULTS[font_count]} user font files"

# S10. NFS
info "Scanning NFS..."
NFS_EXPORTS=false; NFS_MOUNTS=false
[[ -f /etc/exports ]] && grep -qv "^#\|^$" /etc/exports 2>/dev/null && NFS_EXPORTS=true
grep -qE '\bnfs\b|\bnfs4\b' /etc/fstab 2>/dev/null && NFS_MOUNTS=true
SCAN_RESULTS[nfs_exports]="$NFS_EXPORTS"; SCAN_RESULTS[nfs_mounts]="$NFS_MOUNTS"
ok "NFS: exports=$NFS_EXPORTS, fstab mounts=$NFS_MOUNTS"

# S11. SSH
info "Scanning SSH..."
> "$SCAN_TMP/ssh-keys.txt"
if [[ -d "$HOME/.ssh" ]]; then
    find "$HOME/.ssh" -name "id_*" -not -name "*.pub" >> "$SCAN_TMP/ssh-keys.txt" 2>/dev/null || true
    SCAN_RESULTS[ssh_key_count]=$(wc -l < "$SCAN_TMP/ssh-keys.txt")
    ok "SSH: ${SCAN_RESULTS[ssh_key_count]} private key(s) (NOT auto-copied)"
else
    SCAN_RESULTS[ssh_key_count]=0
fi

# S12. Python / npm
info "Scanning language packages..."
touch "$SCAN_TMP/pip-user.txt" "$SCAN_TMP/pipx.txt" "$SCAN_TMP/npm-global.txt"
{ pip list --user --format=columns 2>/dev/null || pip3 list --user --format=columns 2>/dev/null || true; } > "$SCAN_TMP/pip-user.txt"
{ pipx list 2>/dev/null || true; } > "$SCAN_TMP/pipx.txt"
{ npm list -g --depth=0 2>/dev/null || true; } > "$SCAN_TMP/npm-global.txt"

# S13. Systemd
info "Scanning systemd services..."
systemctl list-unit-files --state=enabled --type=service 2>/dev/null > "$SCAN_TMP/systemd-system.txt" || true
systemctl --user list-unit-files --state=enabled --type=service 2>/dev/null > "$SCAN_TMP/systemd-user.txt" || true

# S14. Docker
info "Scanning Docker..."
touch "$SCAN_TMP/docker-images.txt" "$SCAN_TMP/docker-volumes.txt" "$SCAN_TMP/docker-containers.txt"
if command -v docker &>/dev/null; then
    docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" > "$SCAN_TMP/docker-images.txt" 2>/dev/null || true
    docker volume ls > "$SCAN_TMP/docker-volumes.txt" 2>/dev/null || true
    docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" > "$SCAN_TMP/docker-containers.txt" 2>/dev/null || true
    ok "Docker: $(wc -l < "$SCAN_TMP/docker-images.txt") images"
fi

# S15. Hardware
info "Scanning hardware..."
lspci 2>/dev/null > "$SCAN_TMP/lspci.txt" || true
lsmod 2>/dev/null > "$SCAN_TMP/lsmod.txt" || true

# S16. Steam (config only)
> "$SCAN_TMP/steam-info.txt"
> "$SCAN_TMP/steam-config-paths.txt"
STEAM_CONFIG_SUBDIRS=("config" "userdata" "skins" "controller_base")
STEAM_ROOT="$HOME/.local/share/Steam"
STEAM_DOT="$HOME/.steam"
if [[ -d "$STEAM_DOT" ]]; then
    SIZE=$(du -sh "$STEAM_DOT" 2>/dev/null | awk '{print $1}' || echo "?")
    echo "$STEAM_DOT|$SIZE" >> "$SCAN_TMP/steam-info.txt"
    ok "Steam (.steam): $SIZE"
fi
if [[ -d "$STEAM_ROOT" ]]; then
    FULL_SIZE=$(du -sh "$STEAM_ROOT" 2>/dev/null | awk '{print $1}' || echo "?")
    echo "$STEAM_ROOT|$FULL_SIZE (full)" >> "$SCAN_TMP/steam-info.txt"
    ok "Steam full dir: $FULL_SIZE (game files will NOT be copied)"
    for sub in "${STEAM_CONFIG_SUBDIRS[@]}"; do
        D="$STEAM_ROOT/$sub"
        if [[ -d "$D" ]]; then
            SZ=$(du -sh "$D" 2>/dev/null | awk '{print $1}' || echo "?")
            echo "$D|$SZ" >> "$SCAN_TMP/steam-config-paths.txt"
            ok "  Steam config: $sub/ ($SZ)"
        fi
    done
    find "$STEAM_ROOT" -maxdepth 1 -name "*.vdf" 2>/dev/null >> "$SCAN_TMP/steam-config-paths.txt" || true
fi

# S17. Themes
> "$SCAN_TMP/themes.txt"
for d in "$HOME/.themes" "$HOME/.icons" "$HOME/.local/share/themes" "$HOME/.local/share/icons"; do
    [[ -d "$d" ]] && ls "$d" | sed "s|^|$d/|" >> "$SCAN_TMP/themes.txt" || true
done

# S18. Cron
crontab -l > "$SCAN_TMP/crontab.txt" 2>/dev/null || echo "(no crontab)" > "$SCAN_TMP/crontab.txt"

# S19. TurboPrint
info "Scanning TurboPrint..."
TP_FOUND=false
> "$SCAN_TMP/turboprint-info.txt"
if [[ -d /etc/turboprint ]] || [[ -d /usr/share/turboprint ]]; then
    TP_FOUND=true
    echo "TP_FOUND=true" >> "$SCAN_TMP/turboprint-info.txt"

    # Count printer queues
    TP_QUEUES=$(ls /etc/cups/ppd/tp*.ppd 2>/dev/null | wc -l || echo 0)
    echo "TP_QUEUES=$TP_QUEUES" >> "$SCAN_TMP/turboprint-info.txt"

    # Count ICC profiles
    TP_PROFILES=$(ls /usr/share/turboprint/profiles/ 2>/dev/null | wc -l || echo 0)
    echo "TP_PROFILES=$TP_PROFILES" >> "$SCAN_TMP/turboprint-info.txt"

    # Check for license key
    TP_KEY=$(find /etc/turboprint -name "*.tpkey" 2>/dev/null | head -1 || true)
    echo "TP_KEY=$TP_KEY" >> "$SCAN_TMP/turboprint-info.txt"

    # Custom page sizes live in the PPD files — extract them
    > "$SCAN_TMP/turboprint-custom-pagesizes.txt"
    for ppd in /etc/cups/ppd/tp*.ppd; do
        [[ -f "$ppd" ]] || continue
        QNAME=$(basename "$ppd" .ppd)
        grep -i "CustomPageSize\|*PageSize\|custom" "$ppd" 2>/dev/null             | grep -v "^%"             | sed "s/^/$QNAME: /" >> "$SCAN_TMP/turboprint-custom-pagesizes.txt" || true
    done

    ok "TurboPrint: $TP_QUEUES printer queue(s), $TP_PROFILES profile(s)"
    [[ -n "$TP_KEY" ]] && ok "TurboPrint license key found: $TP_KEY"         || warn "TurboPrint: no .tpkey license file found in /etc/turboprint"
else
    ok "TurboPrint: not installed (skipping)"
fi
SCAN_RESULTS[tp_found]="$TP_FOUND"

# S20. CUPS / standard printers
info "Scanning CUPS printers..."
CUPS_QUEUE_COUNT=0
if [[ -f /etc/cups/printers.conf ]]; then
    CUPS_QUEUE_COUNT=$(grep -c "^<Printer " /etc/cups/printers.conf 2>/dev/null || echo 0)
    ok "CUPS: $CUPS_QUEUE_COUNT printer queue(s) found"
else
    ok "CUPS: no printers.conf found (no printers configured)"
fi
CUPS_PPD_COUNT=$(ls /etc/cups/ppd/*.ppd 2>/dev/null | wc -l || echo 0)
SCAN_RESULTS[cups_queues]="$CUPS_QUEUE_COUNT"
SCAN_RESULTS[cups_ppds]="$CUPS_PPD_COUNT"

# S21. DisplayCAL / ArgyllCMS
info "Scanning DisplayCAL / ArgyllCMS..."
DCAL_FOUND=false
DCAL_PROFILE_COUNT=0
> "$SCAN_TMP/displaycal-info.txt"

# ICC profile locations DisplayCAL uses
for dcal_dir in "$HOME/.local/share/color/icc" "$HOME/.color/icc" \
                "$HOME/.local/share/DisplayCAL" \
                "/usr/share/color/icc" "/var/lib/colord/icc"; do
    if [[ -d "$dcal_dir" ]]; then
        DCAL_FOUND=true
        _count=$(find "$dcal_dir" -name "*.icc" -o -name "*.icm" 2>/dev/null | wc -l || echo 0)
        DCAL_PROFILE_COUNT=$(( DCAL_PROFILE_COUNT + _count ))
        echo "$dcal_dir|$_count" >> "$SCAN_TMP/displaycal-info.txt"
    fi
done

# Autostart loader
DCAL_AUTOSTART=""
for _f in "$HOME/.config/autostart/displaycal-apply-profiles.desktop" \
           "$HOME/.config/autostart/displaycal.desktop" \
           /etc/xdg/autostart/displaycal*.desktop; do
    [[ -f "$_f" ]] && DCAL_AUTOSTART="$_f" && break || true
done
echo "autostart=${DCAL_AUTOSTART}" >> "$SCAN_TMP/displaycal-info.txt"

# ArgyllCMS color.jcnf device→profile mapping
[[ -f "$HOME/.config/color.jcnf" ]] && echo "user_jcnf=true" >> "$SCAN_TMP/displaycal-info.txt" || true
[[ -f /etc/xdg/color.jcnf ]]        && echo "sys_jcnf=true"  >> "$SCAN_TMP/displaycal-info.txt" || true

SCAN_RESULTS[dcal_found]="$DCAL_FOUND"
SCAN_RESULTS[dcal_profiles]="$DCAL_PROFILE_COUNT"
[[ "$DCAL_FOUND" == true ]] \
    && ok "DisplayCAL: $DCAL_PROFILE_COUNT ICC profile file(s) across all locations" \
    || ok "DisplayCAL: not found"

# S22. XDG home directories (Documents, Downloads, Pictures, etc.)
info "Scanning XDG home directories..."
> "$SCAN_TMP/home-dirs.txt"
HOME_DIRS_BYTES=0
for xdg in DESKTOP DOWNLOAD TEMPLATES PUBLICSHARE DOCUMENTS MUSIC PICTURES VIDEOS; do
    DIR=$(xdg-user-dir "$xdg" 2>/dev/null || true)
    # Skip if xdg-user-dir returned $HOME itself (dir not configured) or doesn't exist
    [[ -z "$DIR" || "$DIR" == "$HOME" || ! -d "$DIR" ]] && continue
    BYTES=$(du -sb "$DIR" 2>/dev/null | awk '{print $1}' | tr -d '[:space:]' || echo 0)
    BYTES=${BYTES:-0}
    SIZE=$(numfmt --to=iec "$BYTES" 2>/dev/null || echo "?")
    echo "$xdg|$DIR|$SIZE|$BYTES" >> "$SCAN_TMP/home-dirs.txt"
    HOME_DIRS_BYTES=$(( HOME_DIRS_BYTES + BYTES ))
    ok "Home dir: $xdg → $(basename "$DIR") ($SIZE)"
done
SCAN_RESULTS[home_dirs_count]=$(wc -l < "$SCAN_TMP/home-dirs.txt")
SCAN_RESULTS[home_dirs_total]=$(numfmt --to=iec "$HOME_DIRS_BYTES" 2>/dev/null || echo "?")
[[ "${SCAN_RESULTS[home_dirs_count]}" -eq 0 ]] && ok "XDG home dirs: none found"
[[ "$SKIP_HOMEDIRS" == true ]] && warn "Home directory copy SKIPPED (--skip-homedirs)"

# S23. /home/* user directories
info "Scanning /home/ user directories..."
> "$SCAN_TMP/user-homes.txt"
for d in /home/*/; do
    [[ ! -d "$d" ]] && continue
    NAME=$(basename "$d")
    BYTES=$(du -sb "$d" 2>/dev/null | awk '{print $1}' | tr -d '[:space:]' || echo 0)
    BYTES=${BYTES:-0}
    SIZE=$(numfmt --to=iec "$BYTES" 2>/dev/null || echo "?")
    LABEL="$NAME ($SIZE)"
    [[ "$d" == "$HOME/" || "$d" == "${HOME}/" ]] && LABEL="$NAME ($SIZE) ← current user"
    echo "$NAME|$d|$SIZE|$BYTES" >> "$SCAN_TMP/user-homes.txt"
    ok "/home/$NAME: $SIZE"
done
SCAN_RESULTS[user_homes_count]=$(wc -l < "$SCAN_TMP/user-homes.txt")
[[ "${SCAN_RESULTS[user_homes_count]}" -eq 0 ]] && ok "/home/: no user directories found"

# =============================================================================
# PHASE 1 COMPLETE — Write SCAN_SUMMARY.md + print to terminal
# =============================================================================
SUMMARY_DIR="$(dirname "$OUTPUT_DIR")/distro-plopper-scan-$TIMESTAMP"
mkdir -p "$SUMMARY_DIR"
SM="$SUMMARY_DIR/SCAN_SUMMARY.md"

cat > "$SM" << SMEOF
# Distro Plopper — Scan Summary
**Scanned:** $(date)
**Host:** $(hostname)
**OS:** $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
**Kernel:** $(uname -r)
**User:** $USER

> Written at end of Phase 1 (scan only). Exists even if you aborted before backup.

---

## Packages

| Category | Count |
|----------|-------|
| ${PKG_MANAGER} apps | ${SCAN_RESULTS[pacman_apps]:-0} |
| ${PKG_MANAGER} CLI tools | ${SCAN_RESULTS[pacman_cli]:-0} |
| Flatpak apps | ${SCAN_RESULTS[flatpak_count]:-0} |
| AppImages | ${SCAN_RESULTS[appimage_count]:-0} |

### Foreign / 3rd-party Packages
\`\`\`
$(cat "$SCAN_TMP/$PKG_FOREIGN_FILE" 2>/dev/null || echo "(none)")
\`\`\`

### Flatpak Apps
\`\`\`
$(cat "$SCAN_TMP/flatpak-full.txt" 2>/dev/null || echo "(none)")
\`\`\`

### PPAs / External Repos (Ubuntu/Debian)
\`\`\`
$(cat "$SCAN_TMP/ppa-list.txt" 2>/dev/null || echo "(none or not Ubuntu/Debian)")
\`\`\`

### AppImages
\`\`\`
$(cat "$SCAN_TMP/appimages.txt" 2>/dev/null || echo "(none)")
\`\`\`

### pip (user)
\`\`\`
$(cat "$SCAN_TMP/pip-user.txt" 2>/dev/null || echo "(none)")
\`\`\`

### pipx
\`\`\`
$(cat "$SCAN_TMP/pipx.txt" 2>/dev/null || echo "(none)")
\`\`\`

### npm global
\`\`\`
$(cat "$SCAN_TMP/npm-global.txt" 2>/dev/null || echo "(none)")
\`\`\`

---

## Configuration

| Location | Detail |
|----------|--------|
| ~/.config dirs | ${SCAN_RESULTS[config_dir_count]:-0} (${SCAN_RESULTS[config_size]:-?}) |
| Home dotfiles | ${SCAN_RESULTS[dotfile_count]:-0} items |
| ~/.local/share | ${SCAN_RESULTS[local_share_size]:-?} total |
| GNOME extensions | ${SCAN_RESULTS[gnome_ext_count]:-0} |
| dconf dump | ${SCAN_RESULTS[dconf_lines]:-0} lines |

### ~/.config App Config Directories
\`\`\`
$(cat "$SCAN_TMP/config-dirs.txt" 2>/dev/null | xargs -I{} basename {} | sort)
\`\`\`

### Home Dotfiles
\`\`\`
$(cat "$SCAN_TMP/home-dotfiles.txt" 2>/dev/null | xargs -I{} basename {} | sort)
\`\`\`

### ~/.local/share Directories
\`\`\`
$(cat "$SCAN_TMP/local-share-dirs.txt" 2>/dev/null | xargs -I{} basename {} | sort)
\`\`\`

---

## Flatpak App Data (~/.var/app)
Total size: **${SCAN_RESULTS[flatpak_data_size]:-n/a}**

| App ID | config | data | cache |
|--------|--------|------|-------|
SMEOF

while read -r appid; do
    BASE="$HOME/.var/app/$appid"
    C="$( [[ -d "$BASE/config" ]] && echo "✅" || echo "⬜" )"
    D="$( [[ -d "$BASE/data" ]]   && echo "✅" || echo "⬜" )"
    A="$( [[ -d "$BASE/cache" ]]  && echo "✅" || echo "⬜" )"
    echo "| \`$appid\` | $C | $D | $A |" >> "$SM"
done < "$SCAN_TMP/flatpak-apps.txt"

cat >> "$SM" << SMEOF2

---

## Browsers

| Browser | Path | Size |
|---------|------|------|
SMEOF2

if [[ -s "$SCAN_TMP/browser-profiles.txt" ]]; then
    while IFS="|" read -r name dir size; do
        echo "| $name | \`$dir\` | $size |" >> "$SM"
    done < "$SCAN_TMP/browser-profiles.txt"
else
    echo "| — | No browser profiles found | — |" >> "$SM"
fi

cat >> "$SM" << SMEOF3

---

## GNOME

### All Extensions
\`\`\`
$(cat "$SCAN_TMP/gnome-extensions-all.txt" 2>/dev/null || echo "(none)")
\`\`\`

### Enabled Extensions
\`\`\`
$(cat "$SCAN_TMP/gnome-extensions-enabled.txt" 2>/dev/null || echo "(none)")
\`\`\`

### Themes & Icons
\`\`\`
$(cat "$SCAN_TMP/themes.txt" 2>/dev/null || echo "(none)")
\`\`\`

---

## Steam (config & userdata only — game files excluded)

$(if [[ -s "$SCAN_TMP/steam-config-paths.txt" ]]; then
    echo "| Path | Size |"
    echo "|------|------|"
    while IFS="|" read -r path size; do
        echo "| \`$path\` | $size |"
    done < "$SCAN_TMP/steam-config-paths.txt"
else
    echo "_No Steam config found._"
fi)

---

## NFS

| Item | Status |
|------|--------|
| /etc/exports (server) | ${SCAN_RESULTS[nfs_exports]:-false} |
| fstab NFS mounts | ${SCAN_RESULTS[nfs_mounts]:-false} |

### /etc/exports
\`\`\`
$(cat /etc/exports 2>/dev/null || echo "(not found)")
\`\`\`

### NFS fstab entries
\`\`\`
$(grep -E '\bnfs\b|\bnfs4\b' /etc/fstab 2>/dev/null || echo "(none)")
\`\`\`

---

## SSH
| Item | Detail |
|------|--------|
| Private keys found | ${SCAN_RESULTS[ssh_key_count]:-0} (NOT auto-copied) |

### Keys present
\`\`\`
$(cat "$SCAN_TMP/ssh-keys.txt" 2>/dev/null || echo "(none)")
\`\`\`

### ~/.ssh/config
\`\`\`
$(cat "$HOME/.ssh/config" 2>/dev/null || echo "(no config)")
\`\`\`

---

## Fonts
**${SCAN_RESULTS[font_count]:-0} user font files found.**
\`\`\`
$(cat "$SCAN_TMP/fonts.txt" 2>/dev/null | xargs -I{} basename {} | sort -u || echo "(none)")
\`\`\`

---

## Systemd Enabled Services

### System
\`\`\`
$(cat "$SCAN_TMP/systemd-system.txt" 2>/dev/null)
\`\`\`

### User
\`\`\`
$(cat "$SCAN_TMP/systemd-user.txt" 2>/dev/null)
\`\`\`

---

## Docker

### Images
\`\`\`
$(cat "$SCAN_TMP/docker-images.txt" 2>/dev/null || echo "(docker not found)")
\`\`\`

### Volumes
\`\`\`
$(cat "$SCAN_TMP/docker-volumes.txt" 2>/dev/null || echo "(none)")
\`\`\`

### Containers
\`\`\`
$(cat "$SCAN_TMP/docker-containers.txt" 2>/dev/null || echo "(none)")
\`\`\`

---

## Hardware

### GPU / Display
\`\`\`
$(grep -i "vga\|display\|3d\|gpu" "$SCAN_TMP/lspci.txt" 2>/dev/null || echo "(unavailable)")
\`\`\`

### Loaded GPU Modules
\`\`\`
$(grep -iE "amdgpu|radeon|nvidia|nouveau|i915|xe" "$SCAN_TMP/lsmod.txt" 2>/dev/null || echo "(none matched)")
\`\`\`

---

## Cron
\`\`\`
$(cat "$SCAN_TMP/crontab.txt" 2>/dev/null)
\`\`\`

---

## TurboPrint

$(if [[ -f "$SCAN_TMP/turboprint-info.txt" ]] && grep -q "TP_FOUND=true" "$SCAN_TMP/turboprint-info.txt" 2>/dev/null; then
    source "$SCAN_TMP/turboprint-info.txt" 2>/dev/null || true
    echo "| Item | Detail |"
    echo "|------|--------|"
    echo "| Printer queues | $TP_QUEUES |"
    echo "| ICC profiles | $TP_PROFILES |"
    echo "| License key | ${TP_KEY:-not found} |"
    echo ""
    echo "### Custom Page Sizes"
    echo '\`\`\`'
    cat "$SCAN_TMP/turboprint-custom-pagesizes.txt" 2>/dev/null || echo "(none)"
    echo '\`\`\`'
else
    echo "_TurboPrint not installed._"
fi)

---

## XDG Home Directories

| Name | Path | Size |
|------|------|------|
SMEOF3

while IFS="|" read -r xdg dir size _bytes; do
    echo "| $xdg | \`$dir\` | $size |" >> "$SM"
done < "$SCAN_TMP/home-dirs.txt"
[[ ! -s "$SCAN_TMP/home-dirs.txt" ]] && echo "_No XDG home directories found._" >> "$SM"

cat >> "$SM" << SMEOF4

---

## /home User Directories

| User | Path | Size |
|------|------|------|
SMEOF4

while IFS="|" read -r name dir size _bytes; do
    MARKER=""
    [[ "$dir" == "$HOME/" || "$dir" == "${HOME}" ]] && MARKER=" ← current user"
    echo "| $name$MARKER | \`$dir\` | $size |" >> "$SM"
done < "$SCAN_TMP/user-homes.txt"
[[ ! -s "$SCAN_TMP/user-homes.txt" ]] && echo "_No /home directories found._" >> "$SM"

cat >> "$SM" << SMEOF5

---

## Warnings
SMEOF5

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    for w in "${WARNINGS[@]}"; do echo "- ⚠️  $w" >> "$SM"; done
else
    echo "_No warnings._" >> "$SM"
fi
echo "" >> "$SM"
echo "_End of scan summary._" >> "$SM"

# ── Print condensed summary to terminal ───────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  SCAN COMPLETE — Full System Inventory${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
printf "  ${CYAN}%-30s${RESET}\n" "PACKAGES"
printf "  %-30s %s\n" "${PKG_MANAGER^} packages:" "${SCAN_RESULTS[pacman_apps]:-0} apps, ${SCAN_RESULTS[pacman_cli]:-0} CLI tools"
printf "  %-30s %s\n" "Flatpak apps:"     "${SCAN_RESULTS[flatpak_count]:-0}  (data: ${SCAN_RESULTS[flatpak_data_size]:-?})"
printf "  %-30s %s\n" "AppImages:"        "${SCAN_RESULTS[appimage_count]:-0}"
echo ""
printf "  ${CYAN}%-30s${RESET}\n" "CONFIGURATION"
printf "  %-30s %s\n" "~/.config dirs:"   "${SCAN_RESULTS[config_dir_count]:-0}  (${SCAN_RESULTS[config_size]:-?})"
printf "  %-30s %s\n" "Home dotfiles:"    "${SCAN_RESULTS[dotfile_count]:-0}"
printf "  %-30s %s\n" "~/.local/share:"   "${SCAN_RESULTS[local_share_size]:-?}"
printf "  %-30s %s\n" "GNOME extensions:" "${SCAN_RESULTS[gnome_ext_count]:-0}"
printf "  %-30s %s\n" "dconf lines:"      "${SCAN_RESULTS[dconf_lines]:-0}"
echo ""
printf "  ${CYAN}%-30s${RESET}\n" "BROWSERS FOUND"
if [[ -s "$SCAN_TMP/browser-profiles.txt" ]]; then
    while IFS="|" read -r name dir size; do
        printf "  %-30s %s\n" "$name:" "$size"
    done < "$SCAN_TMP/browser-profiles.txt"
else
    printf "  %-30s\n" "None found"
fi
echo ""
printf "  ${CYAN}%-30s${RESET}\n" "OTHER"
printf "  %-30s %s\n" "User fonts:"       "${SCAN_RESULTS[font_count]:-0} files"
printf "  %-30s %s\n" "SSH private keys:" "${SCAN_RESULTS[ssh_key_count]:-0}  (NOT auto-copied)"
printf "  %-30s %s\n" "NFS exports:"      "${SCAN_RESULTS[nfs_exports]:-false}"
printf "  %-30s %s\n" "NFS fstab mounts:" "${SCAN_RESULTS[nfs_mounts]:-false}"
printf "  %-30s %s\n" "XDG home dirs:"    "${SCAN_RESULTS[home_dirs_count]:-0} dirs  (${SCAN_RESULTS[home_dirs_total]:-0} total)"
printf "  %-30s %s\n" "/home/ users:"     "${SCAN_RESULTS[user_homes_count]:-0} found"
echo ""
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    printf "  ${YELLOW}%-30s${RESET}\n" "WARNINGS"
    for w in "${WARNINGS[@]}"; do printf "  ⚠  %s\n" "$w"; done
    echo ""
fi
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  Scan summary → ${BOLD}$SM${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

if [[ "$DRY_RUN" == true ]]; then
    echo -e "\n${YELLOW}  DRY RUN — scan complete, nothing copied.${RESET}\n"
    exit 0
fi

# =============================================================================
# TUI: EXPORT OPTIONS (runs after scan so we have real sizes)
# =============================================================================
USE_TUI=true
command -v whiptail &>/dev/null || USE_TUI=false

if [[ "$USE_TUI" == true ]]; then

TERM_H=$(tput lines); TERM_W=$(tput cols)
BOX_H=$(( TERM_H - 4 )); BOX_W=$(( TERM_W - 8 ))
[[ $BOX_H -lt 20 ]] && BOX_H=20
[[ $BOX_W -lt 70 ]] && BOX_W=70

# ── Welcome ───────────────────────────────────────────────────────────────────
whiptail --title "🪣  Distro Plopper — Export" \
  --msgbox "\
System scan complete. Here's what was found:

  Packages
    ${PKG_MANAGER^}: ${SCAN_RESULTS[pacman_apps]:-0} apps, ${SCAN_RESULTS[pacman_cli]:-0} CLI tools
    Flatpak:  ${SCAN_RESULTS[flatpak_count]:-0} apps  (data: ${SCAN_RESULTS[flatpak_data_size]:-?})
    AppImages:${SCAN_RESULTS[appimage_count]:-0} found

  Configuration
    ~/.config: ${SCAN_RESULTS[config_dir_count]:-0} app dirs  (${SCAN_RESULTS[config_size]:-?})
    Dotfiles:  ${SCAN_RESULTS[dotfile_count]:-0} files
    ~/.local/share: ${SCAN_RESULTS[local_share_size]:-?}
    GNOME extensions: ${SCAN_RESULTS[gnome_ext_count]:-0}
    Fonts: ${SCAN_RESULTS[font_count]:-0} user font files

Next you will:
  1. Choose what to include in the export
  2. Set the output path
  3. Run the backup

Press OK to continue." \
  $BOX_H $BOX_W

# ── Output path ───────────────────────────────────────────────────────────────
# Only prompt if --output was not already given on the command line
if [[ "$OUTPUT_DIR" == "$HOME/distro-plopper-$TIMESTAMP" ]]; then
    PATH_INPUT=$(whiptail --title "Export — Output Location" \
      --inputbox \
"Where should the export bundle be saved?

Default is your home directory. You can specify:
  • A local path:        /home/$USER/my-backup
  • An external drive:   /mnt/usb/plopper-backup
  • A network mount:     /mnt/nas/backups/plopper

Leave blank to use the default." \
      12 $BOX_W "$OUTPUT_DIR" \
      3>&1 1>&2 2>&3) || true

    [[ -n "$PATH_INPUT" ]] && OUTPUT_DIR="$PATH_INPUT"

    # Confirm path is writable (or can be created)
    PARENT_DIR=$(dirname "$OUTPUT_DIR")
    if [[ ! -d "$PARENT_DIR" ]]; then
        whiptail --title "Path Warning" \
          --yesno "Parent directory does not exist:
  $PARENT_DIR

Create it and continue?" \
          10 $BOX_W && mkdir -p "$PARENT_DIR" || { echo "Aborted."; exit 0; }
    fi
    if [[ -d "$OUTPUT_DIR" ]]; then
        whiptail --title "Directory Exists" \
          --yesno "Output directory already exists:
  $OUTPUT_DIR

Files will be merged in (existing files kept). Continue?" \
          10 $BOX_W || { echo "Aborted."; exit 0; }
    fi
fi

# Recalculate archive and summary paths based on final OUTPUT_DIR
SUMMARY_DIR="$(dirname "$OUTPUT_DIR")/distro-plopper-scan-$TIMESTAMP"
ARCHIVE="$(dirname "$OUTPUT_DIR")/distro-plopper-$TIMESTAMP.tar.gz"

# ── What to export ────────────────────────────────────────────────────────────
# Build checklist with sizes from scan

EXP_OPTS=()
EXP_OPTS+=("packages"    "Package lists — ${PKG_MANAGER} (${SCAN_RESULTS[pacman_total]:-0}), Flatpak (${SCAN_RESULTS[flatpak_count]:-0}), AppImages (${SCAN_RESULTS[appimage_count]:-0})" "ON")
EXP_OPTS+=("configs"     "App configs — ~/.config (${SCAN_RESULTS[config_dir_count]:-0} dirs, ${SCAN_RESULTS[config_size]:-?})" "ON")
EXP_OPTS+=("dotfiles"    "Home dotfiles — .bashrc, .zshrc, .gitconfig etc. (${SCAN_RESULTS[dotfile_count]:-0} files)" "ON")
EXP_OPTS+=("localshare"  "~/.local/share app data (${SCAN_RESULTS[local_share_size]:-?} total, Steam excluded)" "ON")
EXP_OPTS+=("gnome"       "GNOME — dconf settings + ${SCAN_RESULTS[gnome_ext_count]:-0} extensions + themes" "ON")
EXP_OPTS+=("ssh"         "SSH config & known_hosts (private keys NOT copied)" "ON")
EXP_OPTS+=("fonts"       "User fonts — ${SCAN_RESULTS[font_count]:-0} files" "ON")
EXP_OPTS+=("nfs"         "NFS — exports=${SCAN_RESULTS[nfs_exports]:-false}, fstab mounts=${SCAN_RESULTS[nfs_mounts]:-false}" "ON")
EXP_OPTS+=("systemd"     "Systemd enabled services (system + user)" "ON")
EXP_OPTS+=("docker"      "Docker inventory — images, volumes, containers (no data)" "ON")
EXP_OPTS+=("hardware"    "Hardware notes — GPU, audio, kernel modules" "ON")

# Flatpak data — warn about size
FLAT_LABEL="Flatpak app data — ~/.var/app (${SCAN_RESULTS[flatpak_data_size]:-?})"
[[ "${SCAN_RESULTS[flatpak_data_size]:-0}" != "n/a" ]] \
    && EXP_OPTS+=("flatpakdata" "$FLAT_LABEL" "ON") \
    || EXP_OPTS+=("flatpakdata" "$FLAT_LABEL [not found]" "OFF")

# Browsers — show each one found
if [[ -s "$SCAN_TMP/browser-profiles.txt" ]]; then
    BROWSER_LIST=$(cut -d'|' -f1 "$SCAN_TMP/browser-profiles.txt" | tr '\n' ', ' | sed 's/,$//')
    BROWSER_TOTAL_BYTES=$(awk -F'|' '{print $2}' "$SCAN_TMP/browser-profiles.txt" \
        | xargs -I{} du -sb {} 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
    BROWSER_TOTAL=$(numfmt --to=iec "$BROWSER_TOTAL_BYTES" 2>/dev/null || echo "?")
    EXP_OPTS+=("browsers" "Browser profiles — $BROWSER_LIST (~$BROWSER_TOTAL total)" "ON")
else
    EXP_OPTS+=("browsers" "Browser profiles — none found" "OFF")
fi

# Steam
if [[ -s "$SCAN_TMP/steam-config-paths.txt" ]]; then
    STEAM_CONF_SIZE=$(du -sh $(awk -F'|' '{print $1}' "$SCAN_TMP/steam-config-paths.txt" | grep -v "\.vdf$" | tr '\n' ' ') 2>/dev/null | tail -1 | awk '{print $1}' || echo "?")
    EXP_OPTS+=("steam" "Steam — config & userdata only, game files excluded (~$STEAM_CONF_SIZE)" "ON")
else
    EXP_OPTS+=("steam" "Steam — not found" "OFF")
fi

# TurboPrint
if [[ "${SCAN_RESULTS[tp_found]:-false}" == "true" ]]; then
    source "$SCAN_TMP/turboprint-info.txt" 2>/dev/null || true
    EXP_OPTS+=("turboprint" "TurboPrint — $TP_QUEUES printer queue(s), $TP_PROFILES ICC profile(s), license key" "ON")
else
    EXP_OPTS+=("turboprint" "TurboPrint — not installed" "OFF")
fi

# CUPS / standard printers
if [[ "${SCAN_RESULTS[cups_queues]:-0}" -gt 0 ]]; then
    EXP_OPTS+=("cups" "CUPS printers — ${SCAN_RESULTS[cups_queues]:-0} queue(s), ${SCAN_RESULTS[cups_ppds]:-0} PPD(s)" "ON")
else
    EXP_OPTS+=("cups" "CUPS printers — none configured" "OFF")
fi

# DisplayCAL / ArgyllCMS
if [[ "${SCAN_RESULTS[dcal_found]:-false}" == "true" ]]; then
    EXP_OPTS+=("displaycal" "DisplayCAL / ArgyllCMS — ${SCAN_RESULTS[dcal_profiles]:-0} ICC profile(s) + autostart loader" "ON")
else
    EXP_OPTS+=("displaycal" "DisplayCAL / ArgyllCMS — not found" "OFF")
fi

EXPORT_CHOICES=$(whiptail --title "Export — Choose What to Include" \
  --checklist \
"Select what to include in the export bundle.
Everything is pre-selected based on what was found.
Deselect anything you don't need to save space/time.

Space = toggle  |  Tab = move to OK/Cancel  |  Enter = confirm  |  Esc = cancel" \
  $BOX_H $BOX_W $(( BOX_H - 10 )) \
  "${EXP_OPTS[@]}" \
  3>&1 1>&2 2>&3) || { echo "Aborted."; exit 0; }

# Parse selections
EXP_PACKAGES=false;    [[ "$EXPORT_CHOICES" == *'"packages"'*    ]] && EXP_PACKAGES=true
EXP_CONFIGS=false;     [[ "$EXPORT_CHOICES" == *'"configs"'*     ]] && EXP_CONFIGS=true
EXP_DOTFILES=false;    [[ "$EXPORT_CHOICES" == *'"dotfiles"'*    ]] && EXP_DOTFILES=true
EXP_LOCALSHARE=false;  [[ "$EXPORT_CHOICES" == *'"localshare"'*  ]] && EXP_LOCALSHARE=true
EXP_GNOME=false;       [[ "$EXPORT_CHOICES" == *'"gnome"'*       ]] && EXP_GNOME=true
EXP_SSH=false;         [[ "$EXPORT_CHOICES" == *'"ssh"'*         ]] && EXP_SSH=true
EXP_FONTS=false;       [[ "$EXPORT_CHOICES" == *'"fonts"'*       ]] && EXP_FONTS=true
EXP_NFS=false;         [[ "$EXPORT_CHOICES" == *'"nfs"'*         ]] && EXP_NFS=true
EXP_SYSTEMD=false;     [[ "$EXPORT_CHOICES" == *'"systemd"'*     ]] && EXP_SYSTEMD=true
EXP_DOCKER=false;      [[ "$EXPORT_CHOICES" == *'"docker"'*      ]] && EXP_DOCKER=true
EXP_HARDWARE=false;    [[ "$EXPORT_CHOICES" == *'"hardware"'*    ]] && EXP_HARDWARE=true
EXP_FLATPAKDATA=false; [[ "$EXPORT_CHOICES" == *'"flatpakdata"'* ]] && EXP_FLATPAKDATA=true
EXP_BROWSERS=false;    [[ "$EXPORT_CHOICES" == *'"browsers"'*    ]] && EXP_BROWSERS=true
EXP_STEAM=false;       [[ "$EXPORT_CHOICES" == *'"steam"'*       ]] && EXP_STEAM=true
EXP_TURBOPRINT=false;  [[ "$EXPORT_CHOICES" == *'"turboprint"'*  ]] && EXP_TURBOPRINT=true
EXP_CUPS=false;        [[ "$EXPORT_CHOICES" == *'"cups"'*         ]] && EXP_CUPS=true
EXP_DISPLAYCAL=false;  [[ "$EXPORT_CHOICES" == *'"displaycal"'*   ]] && EXP_DISPLAYCAL=true

# Override CLI flags with TUI selections
[[ "$EXP_FLATPAKDATA" == false ]] && SKIP_FLATPAK_DATA=true  || SKIP_FLATPAK_DATA=false
[[ "$EXP_BROWSERS"    == false ]] && SKIP_BROWSERS=true      || SKIP_BROWSERS=false
[[ "$EXP_STEAM"       == false ]] && SKIP_STEAM=true         || SKIP_STEAM=false

# ── Home directories sub-selection ───────────────────────────────────────────
> "$SCAN_TMP/home-dirs-selected.txt"
EXP_HOMEDIRS=false
if [[ -s "$SCAN_TMP/home-dirs.txt" ]]; then
    HOMEDIR_OPTS=()
    while IFS="|" read -r xdg dir size _bytes; do
        HOMEDIR_OPTS+=("$xdg" "$(basename "$dir")  ($size)  ←  $dir" "OFF")
    done < "$SCAN_TMP/home-dirs.txt"

    HOMEDIR_CHOICES=$(whiptail --title "Export — Home Directories" \
      --checklist \
"Select which home directories to include.
All are OFF by default — these can be very large.
Only tick what you actually need to migrate.

Space = toggle  |  Tab = move to OK/Cancel  |  Enter = confirm  |  Esc = skip all" \
      $BOX_H $BOX_W $(( BOX_H - 10 )) \
      "${HOMEDIR_OPTS[@]}" \
      3>&1 1>&2 2>&3) || HOMEDIR_CHOICES=""

    while IFS="|" read -r xdg dir size _bytes; do
        [[ "$HOMEDIR_CHOICES" == *"\"$xdg\""* ]] \
            && echo "$xdg|$dir|$size|$_bytes" >> "$SCAN_TMP/home-dirs-selected.txt"
    done < "$SCAN_TMP/home-dirs.txt"
    [[ -s "$SCAN_TMP/home-dirs-selected.txt" ]] && EXP_HOMEDIRS=true
fi

# ── /home user directories sub-selection ─────────────────────────────────────
> "$SCAN_TMP/user-homes-selected.txt"
EXP_USERHOMES=false
if [[ -s "$SCAN_TMP/user-homes.txt" ]]; then
    USERHOME_OPTS=()
    while IFS="|" read -r name dir size _bytes; do
        LABEL="$name  ($size)"
        [[ "$dir" == "$HOME/" || "$dir" == "${HOME}" ]] && LABEL="$name  ($size)  ← current user (already covered by other sections)"
        USERHOME_OPTS+=("$name" "$LABEL" "OFF")
    done < "$SCAN_TMP/user-homes.txt"

    USERHOME_CHOICES=$(whiptail --title "Export — /home User Directories" \
      --checklist \
"Select which /home directories to include.
All are OFF by default — these can be very large.
Current user data is already captured by other sections.

Space = toggle  |  Tab = move to OK/Cancel  |  Enter = confirm  |  Esc = skip all" \
      $BOX_H $BOX_W $(( BOX_H - 10 )) \
      "${USERHOME_OPTS[@]}" \
      3>&1 1>&2 2>&3) || USERHOME_CHOICES=""

    while IFS="|" read -r name dir size _bytes; do
        [[ "$USERHOME_CHOICES" == *"\"$name\""* ]] \
            && echo "$name|$dir|$size|$_bytes" >> "$SCAN_TMP/user-homes-selected.txt"
    done < "$SCAN_TMP/user-homes.txt"
    [[ -s "$SCAN_TMP/user-homes-selected.txt" ]] && EXP_USERHOMES=true
fi

# ── Archive options ───────────────────────────────────────────────────────────
ARCHIVE_CHOICE=$(whiptail --title "Export — Archive Options" \
  --menu \
"After copying all files, distro-plopper can compress
everything into a single .tar.gz archive.

This makes it easier to transfer to a USB drive or
send to another machine.

Archive will be saved to:
  $(dirname "$OUTPUT_DIR")/" \
  15 $BOX_W 3 \
  "yes"  "Create .tar.gz archive (recommended for transfer)" \
  "no"   "Bundle directory only — no archive" \
  "only" "Archive only — delete bundle dir after compressing" \
  3>&1 1>&2 2>&3) || ARCHIVE_CHOICE="yes"

# ── Confirm ───────────────────────────────────────────────────────────────────
SELECTED_LIST=""
[[ "$EXP_PACKAGES"   == true ]] && SELECTED_LIST+="  ✓ Packages (pacman, Flatpak, AppImages)\n"
[[ "$EXP_CONFIGS"    == true ]] && SELECTED_LIST+="  ✓ App configs (~/.config)\n"
[[ "$EXP_DOTFILES"   == true ]] && SELECTED_LIST+="  ✓ Home dotfiles\n"
[[ "$EXP_LOCALSHARE" == true ]] && SELECTED_LIST+="  ✓ ~/.local/share data\n"
[[ "$EXP_FLATPAKDATA" == true ]] && SELECTED_LIST+="  ✓ Flatpak data (${SCAN_RESULTS[flatpak_data_size]:-?})\n"
[[ "$EXP_BROWSERS"   == true ]] && SELECTED_LIST+="  ✓ Browser profiles\n"
[[ "$EXP_GNOME"      == true ]] && SELECTED_LIST+="  ✓ GNOME settings & extensions\n"
[[ "$EXP_SSH"        == true ]] && SELECTED_LIST+="  ✓ SSH config\n"
[[ "$EXP_FONTS"      == true ]] && SELECTED_LIST+="  ✓ Fonts\n"
[[ "$EXP_STEAM"      == true ]] && SELECTED_LIST+="  ✓ Steam config & userdata\n"
[[ "$EXP_TURBOPRINT"  == true ]] && SELECTED_LIST+="  ✓ TurboPrint config, profiles & license\n"
[[ "$EXP_CUPS"        == true ]] && SELECTED_LIST+="  ✓ CUPS printer queues & PPDs\n"
[[ "$EXP_DISPLAYCAL"  == true ]] && SELECTED_LIST+="  ✓ DisplayCAL / ArgyllCMS profiles & config\n"
if [[ "$EXP_HOMEDIRS" == true ]]; then
    while IFS="|" read -r xdg dir size _bytes; do
        SELECTED_LIST+="  ✓ Home dir: $(basename "$dir") ($size)\n"
    done < "$SCAN_TMP/home-dirs-selected.txt"
fi
if [[ "$EXP_USERHOMES" == true ]]; then
    while IFS="|" read -r name dir size _bytes; do
        SELECTED_LIST+="  ✓ /home/$name ($size)\n"
    done < "$SCAN_TMP/user-homes-selected.txt"
fi
[[ "$EXP_NFS"        == true ]] && SELECTED_LIST+="  ✓ NFS configuration\n"
[[ "$EXP_SYSTEMD"    == true ]] && SELECTED_LIST+="  ✓ Systemd services\n"
[[ "$EXP_DOCKER"     == true ]] && SELECTED_LIST+="  ✓ Docker inventory\n"
[[ "$EXP_HARDWARE"   == true ]] && SELECTED_LIST+="  ✓ Hardware notes\n"

whiptail --title "Confirm Export" \
  --yesno "\
Ready to export:

$SELECTED_LIST
Output path:   $OUTPUT_DIR
Archive:       $ARCHIVE_CHOICE

This may take a while depending on what's included.
The terminal will show progress.

Start export?" \
  $BOX_H $BOX_W || { echo "Aborted."; exit 0; }

else
# ── Non-TUI fallback: honour CLI flags as before ──────────────────────────────
EXP_PACKAGES=true; EXP_CONFIGS=true; EXP_DOTFILES=true; EXP_LOCALSHARE=true
EXP_GNOME=true; EXP_SSH=true; EXP_FONTS=true; EXP_NFS=true
EXP_SYSTEMD=true; EXP_DOCKER=true; EXP_HARDWARE=true
EXP_FLATPAKDATA=$( [[ "$SKIP_FLATPAK_DATA" == false ]] && echo true || echo false)
EXP_BROWSERS=$(    [[ "$SKIP_BROWSERS"      == false ]] && echo true || echo false)
EXP_STEAM=$(       [[ "$SKIP_STEAM"         == false ]] && echo true || echo false)
EXP_TURBOPRINT=$(  [[ "${SCAN_RESULTS[tp_found]:-false}"   == "true" ]] && echo true || echo false)
EXP_CUPS=$(        [[ "${SCAN_RESULTS[cups_queues]:-0}" -gt 0        ]] && echo true || echo false)
EXP_DISPLAYCAL=$(  [[ "${SCAN_RESULTS[dcal_found]:-false}"  == "true" ]] && echo true || echo false)
# Non-TUI: --skip-homedirs omits all; otherwise copy every dir found
> "$SCAN_TMP/home-dirs-selected.txt"
if [[ "$SKIP_HOMEDIRS" == false ]] && [[ -s "$SCAN_TMP/home-dirs.txt" ]]; then
    warn "XDG home dirs will ALL be copied (${SCAN_RESULTS[home_dirs_total]:-?} total). Use --skip-homedirs to exclude."
    while IFS="|" read -r xdg dir size _bytes; do
        info "  Will copy: $xdg → $dir ($size)"
    done < "$SCAN_TMP/home-dirs.txt"
    cp "$SCAN_TMP/home-dirs.txt" "$SCAN_TMP/home-dirs-selected.txt"
fi
EXP_HOMEDIRS=$(    [[ -s "$SCAN_TMP/home-dirs-selected.txt" ]] && echo true || echo false)
# Non-TUI: --skip-userhomes omits all; otherwise copy every /home dir found
> "$SCAN_TMP/user-homes-selected.txt"
if [[ "$SKIP_USERHOMES" == false ]] && [[ -s "$SCAN_TMP/user-homes.txt" ]]; then
    warn "/home user dirs will ALL be copied. Use --skip-userhomes to exclude."
    while IFS="|" read -r name dir size _bytes; do
        info "  Will copy: /home/$name ($size)"
    done < "$SCAN_TMP/user-homes.txt"
    cp "$SCAN_TMP/user-homes.txt" "$SCAN_TMP/user-homes-selected.txt"
fi
EXP_USERHOMES=$(   [[ -s "$SCAN_TMP/user-homes-selected.txt" ]] && echo true || echo false)
# Only default to "yes" if --no-archive wasn't passed on the CLI
[[ "$ARCHIVE_CHOICE" != "no" ]] && ARCHIVE_CHOICE="yes"

echo ""
echo -e "  Output directory: ${BOLD}$OUTPUT_DIR${RESET}"
read -rp "  Proceed with full backup? [Y/n] " CONFIRM
[[ "${CONFIRM,,}" == "n" ]] && { echo "  Aborted."; exit 0; }

fi # USE_TUI

# ── copy_with_spinner: run cp -r in background with live size display ────────
copy_with_spinner() {
    # usage: copy_with_spinner "Label" <src> <dest>
    local src="$2" dest="$3"
    # Strip all newlines and control chars from label and size — du can inject them
    local label
    label=$(echo "$1" | tr -d '\n\r')
    mkdir -p "$dest"
    cp -r "$src" "$dest" 2>/dev/null &
    local CP_PID=$!
    local SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local _i=0
    local TERM_W
    TERM_W=$(tput cols 2>/dev/null || echo 100)
    while kill -0 "$CP_PID" 2>/dev/null; do
        local SPIN_CHAR="${SPIN:$(( _i % ${#SPIN} )):1}"
        local CURRENT
        # tail -1 gets the summary line, tr strips any stray newlines
        CURRENT=$(du -sh "$dest" 2>/dev/null | tail -1 | awk '{print $1}' | tr -d '\n\r' || echo "...")
        # Build the line, truncate to terminal width to prevent wrapping
        local LINE="  $SPIN_CHAR  ${label}  ${CURRENT}"
        printf "\r%-${TERM_W}s" "$LINE"
        sleep 0.5
        _i=$(( _i + 1 ))
    done
    wait "$CP_PID" || true
    # Overwrite with done — pad to terminal width to clear any spinner remnants
    printf "\r  ✅  %-${TERM_W}s\n" "$label"
}

# =============================================================================
# PHASE 2: CREATE OUTPUT STRUCTURE
# =============================================================================
header "PHASE 2: Creating output structure..."
mkdir -p "$OUTPUT_DIR"/{packages,configs/{dotfiles,config-dirs,local-share},flatpak,browsers,gnome/extensions-backup,nfs,ssh,fonts,systemd,docker,hardware,steam,homedirs,user-homes,scripts}

MD="$OUTPUT_DIR/MIGRATION_REPORT.md"

log_md()     { echo -e "$*" >> "$MD"; }
section_md() { echo -e "\n---\n\n## $1\n" >> "$MD"; }
note_md()    { echo -e "\n> $1\n" >> "$MD"; }

# Write a machine-readable manifest that import mode will use
MANIFEST="$OUTPUT_DIR/plopper-manifest.txt"
cat > "$MANIFEST" << MEOF
# distro-plopper export manifest
# Generated: $(date)
# Source host: $(hostname)
# Source OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
# Source user: $USER
# Source home: $HOME
MEOF

cat > "$MD" << MDEOF
# Distro Plopper — Migration Report
**Generated:** $(date)
**Host:** $(hostname)
**OS:** $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
**Kernel:** $(uname -r)
**User:** $USER / **Shell:** $SHELL / **DE:** ${XDG_CURRENT_DESKTOP:-unknown}

---

MDEOF

# =============================================================================
# PHASE 3: COPY
# =============================================================================
header "PHASE 3: Copying files..."

# ── Packages ──────────────────────────────────────────────────────────────────
if [[ "$EXP_PACKAGES" == true ]]; then
section_md "1. Packages"
cp "$SCAN_TMP/apps.txt"      "$OUTPUT_DIR/packages/" 2>/dev/null || true
cp "$SCAN_TMP/cli-tools.txt" "$OUTPUT_DIR/packages/" 2>/dev/null || true
cp "$SCAN_TMP"/flatpak-*.txt "$OUTPUT_DIR/packages/" 2>/dev/null || true
cp "$SCAN_TMP/appimages.txt"  "$OUTPUT_DIR/packages/" 2>/dev/null || true
cp "$SCAN_TMP/pip-user.txt" "$SCAN_TMP/pipx.txt" "$SCAN_TMP/npm-global.txt" "$OUTPUT_DIR/packages/" 2>/dev/null || true
echo "packages_present=true"                        >> "$MANIFEST"
echo "pkg_manager=$PKG_MANAGER"                     >> "$MANIFEST"
echo "pkg_family=$PKG_FAMILY"                       >> "$MANIFEST"
echo "pkg_apps_file=apps.txt"                       >> "$MANIFEST"
echo "flatpak_count=${SCAN_RESULTS[flatpak_count]:-0}" >> "$MANIFEST"
note_md "Restore apps: \`$PKG_INSTALL < packages/apps.txt\`"
note_md "Restore Flatpak: \`flatpak install \$(cat packages/flatpak-apps.txt)\`"
log_md "### ${PKG_MANAGER^}: ${SCAN_RESULTS[pacman_apps]:-0} apps, ${SCAN_RESULTS[pacman_cli]:-0} CLI tools"
log_md "#### Apps"; log_md '```'; cat "$SCAN_TMP/apps.txt" >> "$MD"; log_md '```'
log_md "#### CLI tools (reference only)"; log_md '```'; cat "$SCAN_TMP/cli-tools.txt" >> "$MD"; log_md '```'
log_md "### Flatpak: ${SCAN_RESULTS[flatpak_count]:-0} apps"
log_md '```'; cat "$SCAN_TMP/flatpak-full.txt" >> "$MD"; log_md '```'
log_md "### AppImages"
log_md '```'; cat "$SCAN_TMP/appimages.txt" >> "$MD"; log_md '```'
ok "Package lists saved (${PKG_MANAGER})"
fi # EXP_PACKAGES

# ── ~/.config full copy ───────────────────────────────────────────────────────
if [[ "$EXP_CONFIGS" == true ]]; then
section_md "2. Application Configs (~/.config)"
note_md "All app config directories captured."
log_md "| App | Size |"; log_md "|-----|------|"
> "$OUTPUT_DIR/packages/config-dirs-list.txt"
while read -r dir; do
    APP=$(basename "$dir")
    SIZE=$(du -sh "$dir" 2>/dev/null | tail -1 | awk '{print $1}' | tr -d '\n\r' || echo "?")
    cp -r "$dir" "$OUTPUT_DIR/configs/config-dirs/" 2>/dev/null || true
    log_md "| \`$APP\` | $SIZE |"
    echo "$APP" >> "$OUTPUT_DIR/packages/config-dirs-list.txt"
done < "$SCAN_TMP/config-dirs.txt"
while read -r f; do cp "$f" "$OUTPUT_DIR/configs/config-dirs/" 2>/dev/null || true; done < "$SCAN_TMP/config-files.txt"
echo "config_dirs_present=true" >> "$MANIFEST"
ok "~/.config copied (${SCAN_RESULTS[config_dir_count]:-0} dirs)"
fi # EXP_CONFIGS

# ── Home dotfiles ─────────────────────────────────────────────────────────────
if [[ "$EXP_DOTFILES" == true ]]; then
section_md "3. Home Dotfiles"
log_md "| File | Size |"; log_md "|------|------|"
while read -r item; do
    NAME=$(basename "$item")
    case "$NAME" in .cache|.dbus|.gvfs|.Trash|.recently-used*) continue ;; esac
    SIZE=$(du -sh "$item" 2>/dev/null | tail -1 | awk '{print $1}' | tr -d '\n\r' || echo "?")
    cp -r "$item" "$OUTPUT_DIR/configs/dotfiles/" 2>/dev/null || true
    log_md "| \`$NAME\` | $SIZE |"
done < "$SCAN_TMP/home-dotfiles.txt"
echo "dotfiles_present=true" >> "$MANIFEST"
ok "Home dotfiles copied"
fi # EXP_DOTFILES

# ── ~/.local/share ────────────────────────────────────────────────────────────
if [[ "$EXP_LOCALSHARE" == true ]]; then
section_md "4. ~/.local/share"
log_md "| Directory | Size | Copied |"; log_md "|-----------|------|--------|"
SKIP_LOCAL=("Steam" "Trash" "gvfs" "recently-used.xbel" "recently-used" "recently_used.xbel")
while read -r dir; do
    NAME=$(basename "$dir")
    DIR_BYTES=$(du -sb "$dir" 2>/dev/null | tail -1 | awk '{print $1}' | tr -d '[:space:]' || echo 0)
    SIZE=$(numfmt --to=iec "${DIR_BYTES:-0}" 2>/dev/null || echo "?")
    SKIP=false
    for s in "${SKIP_LOCAL[@]}"; do [[ "$NAME" == "$s" ]] && SKIP=true && break; done
    if [[ "$SKIP" == true ]]; then
        log_md "| \`$NAME\` | $SIZE | ⬜ excluded |"
    else
        # Use spinner for dirs over 100MB
        if [[ "$DIR_BYTES" -gt 104857600 ]]; then
            copy_with_spinner "~/.local/share/$NAME ($SIZE)" "$dir" "$OUTPUT_DIR/configs/local-share/"
        else
            cp -r "$dir" "$OUTPUT_DIR/configs/local-share/" 2>/dev/null || true
        fi
        log_md "| \`$NAME\` | $SIZE | ✅ |"
    fi
done < "$SCAN_TMP/local-share-dirs.txt"
echo "local_share_present=true" >> "$MANIFEST"
ok "~/.local/share copied (Steam game files excluded)"
fi # EXP_LOCALSHARE

# ── Steam config ──────────────────────────────────────────────────────────────
if [[ "$EXP_STEAM" == true ]]; then
section_md "4b. Steam Config (config & userdata only)"
note_md "Game files NOT backed up. Restore to \`~/.local/share/Steam/\` after installing Steam."
if [[ "$SKIP_STEAM" == false ]] && [[ -s "$SCAN_TMP/steam-config-paths.txt" ]]; then
    log_md "| Path | Size |"; log_md "|------|------|"
    while IFS="|" read -r path size; do
        if [[ -d "$path" ]]; then
            DEST_NAME=$(basename "$path")
            cp -r "$path" "$OUTPUT_DIR/steam/$DEST_NAME" 2>/dev/null || true
            ACTUAL=$(du -sh "$OUTPUT_DIR/steam/$DEST_NAME" 2>/dev/null | awk '{print $1}' || echo "?")
            log_md "| \`$path\` | $ACTUAL |"
            ok "Steam: $DEST_NAME ($ACTUAL)"
        elif [[ -f "$path" ]]; then
            cp "$path" "$OUTPUT_DIR/steam/" 2>/dev/null || true
            log_md "| \`$path\` | (vdf) |"
        fi
    done < "$SCAN_TMP/steam-config-paths.txt"
    [[ -d "$HOME/.steam" ]] && cp -rL "$HOME/.steam" "$OUTPUT_DIR/steam/dot-steam" 2>/dev/null || true
    echo "steam_present=true" >> "$MANIFEST"
    echo "steam_root=$STEAM_ROOT" >> "$MANIFEST"
else
    log_md "_Skipped._"
    echo "steam_present=false" >> "$MANIFEST"
fi
fi # EXP_STEAM

# ── Flatpak ~/.var/app ────────────────────────────────────────────────────────
if [[ "$EXP_FLATPAKDATA" == true ]]; then
section_md "5. Flatpak App Data (~/.var/app)"
if [[ "$SKIP_FLATPAK_DATA" == false ]] && [[ -d "$HOME/.var/app" ]]; then
    copy_with_spinner "Flatpak ~/.var/app (${SCAN_RESULTS[flatpak_data_size]:-?})" "$HOME/.var/app" "$OUTPUT_DIR/flatpak/var-app"
    ACTUAL=$(du -sh "$OUTPUT_DIR/flatpak/var-app" 2>/dev/null | tail -1 | awk '{print $1}' || echo "?")
    log_md "Backed up: $ACTUAL"
    echo "flatpak_data_present=true" >> "$MANIFEST"
    ok "Flatpak ~/.var/app copied ($ACTUAL)"
else
    log_md "_Skipped._"
    echo "flatpak_data_present=false" >> "$MANIFEST"
fi
log_md ""; log_md "| App ID | config | data | cache |"; log_md "|--------|--------|------|-------|"
while read -r appid; do
    BASE="$HOME/.var/app/$appid"
    C="$( [[ -d "$BASE/config" ]] && echo "✅" || echo "⬜" )"
    D="$( [[ -d "$BASE/data" ]]   && echo "✅" || echo "⬜" )"
    A="$( [[ -d "$BASE/cache" ]]  && echo "✅" || echo "⬜" )"
    log_md "| \`$appid\` | $C | $D | $A |"
done < "$SCAN_TMP/flatpak-apps.txt"
fi # EXP_FLATPAKDATA

# ── Browsers ──────────────────────────────────────────────────────────────────
if [[ "$EXP_BROWSERS" == true ]]; then
section_md "6. Browser Profiles"
note_md "⚠️  Contains cookies, sessions, passwords. Store securely."
if [[ "$SKIP_BROWSERS" == false ]] && [[ -s "$SCAN_TMP/browser-profiles.txt" ]]; then
    log_md "| Browser | Original Path | Size |"
    log_md "|---------|--------------|------|"
    while IFS="|" read -r name dir size; do
        SAFE="${name// /_}"
        mkdir -p "$OUTPUT_DIR/browsers/$SAFE"
        copy_with_spinner "Browser: $name ($size)" "$dir" "$OUTPUT_DIR/browsers/$SAFE/"
        ACTUAL=$(du -sh "$OUTPUT_DIR/browsers/$SAFE" 2>/dev/null | tail -1 | awk '{print $1}' || echo "?")
        log_md "| $name | \`$dir\` | $ACTUAL |"
        # Write restore mapping to manifest
        echo "browser:$name:$dir:browsers/$SAFE" >> "$MANIFEST"
        ok "Browser: $name ($ACTUAL)"
    done < "$SCAN_TMP/browser-profiles.txt"
    echo "browsers_present=true" >> "$MANIFEST"
else
    log_md "_Skipped._"
    echo "browsers_present=false" >> "$MANIFEST"
fi
fi # EXP_BROWSERS

# ── GNOME ─────────────────────────────────────────────────────────────────────
if [[ "$EXP_GNOME" == true ]]; then
section_md "7. GNOME Configuration"
cp "$SCAN_TMP/gnome-extensions-all.txt" "$SCAN_TMP/gnome-extensions-enabled.txt" "$SCAN_TMP/dconf-full.ini" "$OUTPUT_DIR/gnome/" 2>/dev/null || true
if command -v dconf &>/dev/null; then
    for ns in /org/gnome/shell /org/gnome/desktop /org/gnome/settings-daemon /org/gnome/mutter /org/gnome/terminal /org/gtk; do
        SAFE="${ns//\//_}"; SAFE="${SAFE#_}"
        dconf dump "$ns/" > "$OUTPUT_DIR/gnome/dconf-${SAFE}.ini" 2>/dev/null || true
    done
fi
USER_EXT="$HOME/.local/share/gnome-shell/extensions"
[[ -d "$USER_EXT" ]] && cp -r "$USER_EXT"/. "$OUTPUT_DIR/gnome/extensions-backup/" 2>/dev/null || true
echo "gnome_present=true" >> "$MANIFEST"
note_md "Restore: \`dconf load / < gnome/dconf-full.ini\`"
log_md "### Extensions"; log_md '```'; cat "$SCAN_TMP/gnome-extensions-all.txt" >> "$MD"; log_md '```'
log_md "### Themes & Icons"; log_md '```'; cat "$SCAN_TMP/themes.txt" >> "$MD"; log_md '```'
ok "GNOME config copied"
fi # EXP_GNOME

# ── NFS ───────────────────────────────────────────────────────────────────────
if [[ "$EXP_NFS" == true ]]; then
section_md "8. NFS"
[[ -f /etc/exports ]] && cp /etc/exports "$OUTPUT_DIR/nfs/exports" 2>/dev/null || true
grep -E '\bnfs\b|\bnfs4\b' /etc/fstab 2>/dev/null > "$OUTPUT_DIR/nfs/fstab-nfs-lines" || true
echo "nfs_exports=${SCAN_RESULTS[nfs_exports]:-false}" >> "$MANIFEST"
echo "nfs_mounts=${SCAN_RESULTS[nfs_mounts]:-false}" >> "$MANIFEST"
log_md "### /etc/exports"; log_md '```'
[[ -f /etc/exports ]] && cat /etc/exports >> "$MD" || log_md "(not found)"
log_md '```'
log_md "### NFS fstab entries"; log_md '```'
grep -E '\bnfs\b|\bnfs4\b' /etc/fstab 2>/dev/null >> "$MD" || log_md "(none)"
log_md '```'
log_md "### Full /etc/fstab"; log_md '```'; cat /etc/fstab >> "$MD"; log_md '```'
fi # EXP_NFS

# ── SSH ───────────────────────────────────────────────────────────────────────
if [[ "$EXP_SSH" == true ]]; then
section_md "9. SSH"
note_md "⚠️  Private keys NOT copied. Copy \`~/.ssh/id_*\` manually. \`chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_*\`"
[[ -f "$HOME/.ssh/config" ]]          && cp "$HOME/.ssh/config"          "$OUTPUT_DIR/ssh/"
[[ -f "$HOME/.ssh/known_hosts" ]]     && cp "$HOME/.ssh/known_hosts"     "$OUTPUT_DIR/ssh/"
[[ -f "$HOME/.ssh/authorized_keys" ]] && cp "$HOME/.ssh/authorized_keys" "$OUTPUT_DIR/ssh/"
echo "ssh_present=true" >> "$MANIFEST"
log_md "### SSH Config"; log_md '```'
[[ -f "$HOME/.ssh/config" ]] && cat "$HOME/.ssh/config" >> "$MD" || log_md "(no config)"
log_md '```'
log_md "### Private Keys (copy manually)"; log_md '```'; cat "$SCAN_TMP/ssh-keys.txt" >> "$MD"; log_md '```'
fi # EXP_SSH

# ── Fonts ─────────────────────────────────────────────────────────────────────
if [[ "$EXP_FONTS" == true ]]; then
section_md "10. Fonts"
for FDIR in "$HOME/.local/share/fonts" "$HOME/.fonts"; do
    [[ -d "$FDIR" ]] && cp -r "$FDIR" "$OUTPUT_DIR/fonts/$(basename "$FDIR")" 2>/dev/null || true
done
echo "fonts_present=true" >> "$MANIFEST"
log_md "**${SCAN_RESULTS[font_count]:-0} font files** backed up."
log_md '```'; cat "$SCAN_TMP/fonts.txt" | xargs -I{} basename {} 2>/dev/null | sort -u >> "$MD" || true; log_md '```'
fi # EXP_FONTS

# ── XDG home directories ──────────────────────────────────────────────────────
if [[ "$EXP_HOMEDIRS" == true ]]; then
section_md "10b. XDG Home Directories"
note_md "⚠️  These can be large. Copied with no-overwrite on restore."
log_md "| XDG Name | Path | Size |"; log_md "|----------|------|------|"
while IFS="|" read -r xdg dir size _bytes; do
    DEST_NAME=$(basename "$dir")
    DIR_BYTES=$(echo "${_bytes:-0}" | tr -d '[:space:]')
    DIR_BYTES=${DIR_BYTES:-0}
    if [[ "$DIR_BYTES" -gt 104857600 ]]; then
        copy_with_spinner "homedirs/$DEST_NAME ($size)" "$dir" "$OUTPUT_DIR/homedirs/"
    else
        cp -r "$dir" "$OUTPUT_DIR/homedirs/" 2>/dev/null || true
    fi
    log_md "| $xdg | \`$dir\` | $size |"
    echo "homedir:$xdg:$dir:homedirs/$DEST_NAME" >> "$MANIFEST"
done < "$SCAN_TMP/home-dirs-selected.txt"
echo "homedirs_present=true" >> "$MANIFEST"
ok "XDG home directories copied"
fi # EXP_HOMEDIRS

# ── /home user directories ────────────────────────────────────────────────────
if [[ "$EXP_USERHOMES" == true ]]; then
section_md "10c. /home User Directories"
note_md "⚠️  Restore requires sudo. Copied with no-overwrite."
log_md "| User | Path | Size |"; log_md "|------|------|------|"
while IFS="|" read -r name dir size _bytes; do
    DIR_BYTES=$(echo "${_bytes:-0}" | tr -d '[:space:]'); DIR_BYTES=${DIR_BYTES:-0}
    if [[ "$DIR_BYTES" -gt 104857600 ]]; then
        copy_with_spinner "user-homes/$name ($size)" "$dir" "$OUTPUT_DIR/user-homes/"
    else
        cp -r "$dir" "$OUTPUT_DIR/user-homes/" 2>/dev/null || true
    fi
    log_md "| $name | \`$dir\` | $size |"
    echo "userhome:$name:$dir:user-homes/$name" >> "$MANIFEST"
done < "$SCAN_TMP/user-homes-selected.txt"
echo "user_homes_present=true" >> "$MANIFEST"
ok "/home user directories copied"
fi # EXP_USERHOMES

# ── System configs ────────────────────────────────────────────────────────────
section_md "11. System Configuration" # always included
for f in /etc/default/grub /etc/environment /etc/hosts /etc/locale.conf; do
    [[ -f "$f" ]] && cp "$f" "$OUTPUT_DIR/configs/" 2>/dev/null || true
done
case "$PKG_FAMILY" in
    arch)
        for f in /etc/pacman.conf /etc/makepkg.conf; do [[ -f "$f" ]] && cp "$f" "$OUTPUT_DIR/configs/" 2>/dev/null || true; done
        log_md "### pacman.conf"; log_md '```'
        grep -v "^#\|^$" /etc/pacman.conf 2>/dev/null >> "$MD" || true; log_md '```'
        log_md "### makepkg.conf (compile flags)"; log_md '```'
        grep -E "^MAKEFLAGS|^RUSTFLAGS|^CFLAGS|^CXXFLAGS|^PKGEXT" /etc/makepkg.conf 2>/dev/null >> "$MD" || true; log_md '```'
        ;;
    fedora)
        [[ -f /etc/dnf/dnf.conf ]] && cp /etc/dnf/dnf.conf "$OUTPUT_DIR/configs/" 2>/dev/null || true
        log_md "### dnf.conf"; log_md '```'
        cat /etc/dnf/dnf.conf 2>/dev/null >> "$MD" || true; log_md '```'
        log_md "### Enabled repos"; log_md '```'
        dnf repolist --enabled 2>/dev/null >> "$MD" || true; log_md '```'
        ;;
    debian)
        [[ -f /etc/apt/sources.list ]] && cp /etc/apt/sources.list "$OUTPUT_DIR/configs/" 2>/dev/null || true
        [[ -d /etc/apt/sources.list.d ]] && cp -r /etc/apt/sources.list.d "$OUTPUT_DIR/configs/" 2>/dev/null || true
        # Ubuntu: also copy apt keyrings (needed to re-add PPAs/repos)
        [[ -d /etc/apt/trusted.gpg.d ]] && cp -r /etc/apt/trusted.gpg.d "$OUTPUT_DIR/configs/apt-keyrings/" 2>/dev/null || true
        [[ -d /usr/share/keyrings ]]    && cp -r /usr/share/keyrings     "$OUTPUT_DIR/configs/apt-keyrings-usr/" 2>/dev/null || true
        # Copy PPA lists captured during scan
        [[ -f "$SCAN_TMP/ppa-list.txt"    ]] && cp "$SCAN_TMP/ppa-list.txt"    "$OUTPUT_DIR/packages/" 2>/dev/null || true
        [[ -f "$SCAN_TMP/ppa-sources.txt" ]] && cp "$SCAN_TMP/ppa-sources.txt" "$OUTPUT_DIR/packages/" 2>/dev/null || true
        [[ -f "$SCAN_TMP/$PKG_FOREIGN_FILE" ]] && cp "$SCAN_TMP/$PKG_FOREIGN_FILE" "$OUTPUT_DIR/packages/" 2>/dev/null || true
        echo "pkg_subfamily=$PKG_SUBFAMILY" >> "$MANIFEST"
        log_md "### apt sources"; log_md '```'
        cat /etc/apt/sources.list 2>/dev/null >> "$MD" || true; log_md '```'
        log_md "### PPAs / external repos"; log_md '```'
        cat "$SCAN_TMP/ppa-list.txt" 2>/dev/null >> "$MD" || echo "(none)" >> "$MD"; log_md '```'
        if [[ "$PKG_SUBFAMILY" == "ubuntu" ]]; then
            log_md "### PPA restore commands"; log_md '```'
            cat "$SCAN_TMP/ppa-sources.txt" 2>/dev/null | while read -r ppa; do
                echo "sudo add-apt-repository -y $ppa"
            done >> "$MD" || true; log_md '```'
        fi
        ;;
    suse)
        log_md "### zypper repos"; log_md '```'
        zypper repos 2>/dev/null >> "$MD" || true; log_md '```'
        ;;
esac
log_md "### GRUB"; log_md '```'
grep -v "^#\|^$" /etc/default/grub 2>/dev/null >> "$MD" || true; log_md '```'
log_md "### Locale & Timezone"; log_md '```'
localectl status 2>/dev/null >> "$MD" || true; log_md '```'

# ── Systemd ───────────────────────────────────────────────────────────────────
if [[ "$EXP_SYSTEMD" == true ]]; then
section_md "12. Systemd"
cp "$SCAN_TMP/systemd-system.txt" "$OUTPUT_DIR/systemd/system-enabled.txt" 2>/dev/null || true
cp "$SCAN_TMP/systemd-user.txt"   "$OUTPUT_DIR/systemd/user-enabled.txt"   2>/dev/null || true
log_md "### System"; log_md '```'; cat "$SCAN_TMP/systemd-system.txt" >> "$MD"; log_md '```'
log_md "### User"; log_md '```'; cat "$SCAN_TMP/systemd-user.txt" >> "$MD"; log_md '```'
fi # EXP_SYSTEMD

# ── Docker ────────────────────────────────────────────────────────────────────
if [[ "$EXP_DOCKER" == true ]]; then
section_md "13. Docker"
note_md "Images/volumes NOT backed up. Use \`docker save\` manually."
cp "$SCAN_TMP"/docker-*.txt "$OUTPUT_DIR/docker/" 2>/dev/null || true
log_md "### Images"; log_md '```'; cat "$SCAN_TMP/docker-images.txt" >> "$MD"; log_md '```'
log_md "### Volumes"; log_md '```'; cat "$SCAN_TMP/docker-volumes.txt" >> "$MD"; log_md '```'
fi # EXP_DOCKER

# ── Hardware ──────────────────────────────────────────────────────────────────
if [[ "$EXP_HARDWARE" == true ]]; then
section_md "14. Hardware"
cp "$SCAN_TMP/lspci.txt" "$SCAN_TMP/lsmod.txt" "$OUTPUT_DIR/hardware/" 2>/dev/null || true
log_md "### GPU"; log_md '```'; grep -i "vga\|display\|3d\|gpu" "$SCAN_TMP/lspci.txt" >> "$MD" 2>/dev/null || true; log_md '```'
log_md "### GPU Modules"; log_md '```'; grep -iE "amdgpu|radeon|nvidia|nouveau|i915|xe" "$SCAN_TMP/lsmod.txt" >> "$MD" 2>/dev/null || true; log_md '```'
fi # EXP_HARDWARE

# ── CUPS / standard printers ────────────────────────────────────────────────
if [[ "$EXP_CUPS" == true ]] && [[ "${SCAN_RESULTS[cups_queues]:-0}" -gt 0 ]]; then
    section_md "14b. CUPS Printer Configuration"
    note_md "Restore: copy files then \`sudo systemctl restart cups\`"
    note_md "Note: USB printer URIs are hardware-specific. Network printers (IPP/socket) migrate cleanly."
    mkdir -p "$OUTPUT_DIR/cups"

    [[ -f /etc/cups/printers.conf ]] && sudo cp /etc/cups/printers.conf "$OUTPUT_DIR/cups/" 2>/dev/null || true
    [[ -f /etc/cups/cupsd.conf    ]] && sudo cp /etc/cups/cupsd.conf    "$OUTPUT_DIR/cups/" 2>/dev/null || true
    [[ -f /etc/cups/lpoptions     ]] && sudo cp /etc/cups/lpoptions     "$OUTPUT_DIR/cups/" 2>/dev/null || true
    [[ -d /etc/cups/ppd           ]] && sudo cp -r /etc/cups/ppd        "$OUTPUT_DIR/cups/" 2>/dev/null || true
    [[ -f "$HOME/.cups/lpoptions" ]] && { mkdir -p "$OUTPUT_DIR/cups/user-cups"; cp "$HOME/.cups/lpoptions" "$OUTPUT_DIR/cups/user-cups/" 2>/dev/null || true; }

    echo "cups_present=true" >> "$MANIFEST"
    log_md "### Printer Queues"
    log_md '```'
    grep -E "^<Printer|DeviceURI|Info|Location" /etc/cups/printers.conf 2>/dev/null >> "$MD" || log_md "(none)"
    log_md '```'
    log_md "### PPD files"
    log_md '```'
    ls /etc/cups/ppd/ 2>/dev/null >> "$MD" || log_md "(none)"
    log_md '```'
    ok "CUPS config copied (${SCAN_RESULTS[cups_queues]:-0} queues)"
fi

# ── DisplayCAL / ArgyllCMS ────────────────────────────────────────────────────
if [[ "$EXP_DISPLAYCAL" == true ]] && [[ "${SCAN_RESULTS[dcal_found]:-false}" == "true" ]]; then
    section_md "14c. DisplayCAL / ArgyllCMS"
    note_md "ICC profiles are monitor+hardware specific. Copying preserves your calibrations."
    note_md "⚠️  Profile assignment (colord device mapping) is tied to monitor EDID. Same monitor = automatic. Different monitor = re-run calibration."
    mkdir -p "$OUTPUT_DIR/displaycal"/{icc-user,icc-home,displaycal-storage,autostart,colord}

    # User ICC profile locations
    [[ -d "$HOME/.local/share/color/icc" ]] && cp -r "$HOME/.local/share/color/icc" "$OUTPUT_DIR/displaycal/icc-user/" 2>/dev/null || true
    [[ -d "$HOME/.color/icc"             ]] && cp -r "$HOME/.color/icc"             "$OUTPUT_DIR/displaycal/icc-home/" 2>/dev/null || true

    # DisplayCAL storage (calibration sessions, settings, ICCs)
    [[ -d "$HOME/.local/share/DisplayCAL" ]] && cp -r "$HOME/.local/share/DisplayCAL" "$OUTPUT_DIR/displaycal/displaycal-storage/" 2>/dev/null || true

    # ArgyllCMS device→profile mapping
    [[ -f "$HOME/.config/color.jcnf" ]] && cp "$HOME/.config/color.jcnf" "$OUTPUT_DIR/displaycal/" 2>/dev/null || true
    [[ -f /etc/xdg/color.jcnf        ]] && cp /etc/xdg/color.jcnf        "$OUTPUT_DIR/displaycal/sys-color.jcnf" 2>/dev/null || true

    # Autostart loader (critical for profile loading on login)
    for _f in "$HOME/.config/autostart/displaycal-apply-profiles.desktop" \
               "$HOME/.config/autostart/displaycal.desktop" \
               /etc/xdg/autostart/displaycal*.desktop; do
        [[ -f "$_f" ]] && cp "$_f" "$OUTPUT_DIR/displaycal/autostart/" 2>/dev/null || true
    done

    # colord database (device→profile assignments)
    [[ -d /var/lib/colord ]] && sudo cp -r /var/lib/colord "$OUTPUT_DIR/displaycal/colord/" 2>/dev/null || true

    # System-wide ICC profiles that DisplayCAL installed
    [[ -d /usr/share/color/icc ]] && cp -r /usr/share/color/icc "$OUTPUT_DIR/displaycal/icc-system/" 2>/dev/null || true

    echo "displaycal_present=true" >> "$MANIFEST"
    log_md "### ICC Profile Locations"
    log_md '```'
    while read -r line; do
        DIR="${line%%|*}"; COUNT="${line##*|}"
        echo "$DIR ($COUNT files)" >> "$MD"
    done < "$SCAN_TMP/displaycal-info.txt" 2>/dev/null || true
    log_md '```'
    log_md "### Autostart loader"
    log_md '```'
    grep "autostart=" "$SCAN_TMP/displaycal-info.txt" >> "$MD" 2>/dev/null || log_md "(none found)"
    log_md '```'
    ok "DisplayCAL config + ${SCAN_RESULTS[dcal_profiles]:-0} ICC profiles copied"
fi

# ── TurboPrint ───────────────────────────────────────────────────────────────
if [[ "$EXP_TURBOPRINT" == true ]] && [[ "${SCAN_RESULTS[tp_found]:-false}" == "true" ]]; then
    section_md "15. TurboPrint"
    note_md "⚠️  Install TurboPrint on the new system FIRST, then restore these files."
    note_md "License key: re-run \`sudo tpsetup --install <keyfile>\` after copying."
    mkdir -p "$OUTPUT_DIR/turboprint/"{config,profiles,ppd,user}

    # /etc/turboprint — main config + license key
    if [[ -d /etc/turboprint ]]; then
        cp -r /etc/turboprint/. "$OUTPUT_DIR/turboprint/config/" 2>/dev/null || true
        ok "TurboPrint: /etc/turboprint copied"
        log_md "### /etc/turboprint (config + license key)"
        log_md '```'
        ls -la /etc/turboprint/ 2>/dev/null >> "$MD" || true
        log_md '```'
    fi

    # CUPS PPD files for TurboPrint queues
    if ls /etc/cups/ppd/tp*.ppd &>/dev/null 2>&1; then
        cp /etc/cups/ppd/tp*.ppd "$OUTPUT_DIR/turboprint/ppd/" 2>/dev/null || true
        ok "TurboPrint: CUPS PPD files copied ($(ls /etc/cups/ppd/tp*.ppd 2>/dev/null | wc -l) queues)"
        log_md "### CUPS PPD files (printer queues)"
        log_md '```'
        ls /etc/cups/ppd/tp*.ppd 2>/dev/null >> "$MD" || true
        log_md '```'
    fi

    # ICC profiles
    if [[ -d /usr/share/turboprint/profiles ]] && [[ -n "$(ls /usr/share/turboprint/profiles/ 2>/dev/null)" ]]; then
        cp -r /usr/share/turboprint/profiles/. "$OUTPUT_DIR/turboprint/profiles/" 2>/dev/null || true
        PROF_COUNT=$(ls "$OUTPUT_DIR/turboprint/profiles/" 2>/dev/null | wc -l)
        ok "TurboPrint: $PROF_COUNT ICC profiles copied"
        log_md "### ICC Profiles (/usr/share/turboprint/profiles/)"
        log_md '```'
        ls /usr/share/turboprint/profiles/ 2>/dev/null >> "$MD" || true
        log_md '```'
    fi

    # Per-user settings file
    [[ -f "$HOME/.turboprint" ]] && cp "$HOME/.turboprint" "$OUTPUT_DIR/turboprint/user/dot-turboprint" 2>/dev/null || true

    # Custom page sizes extracted from PPDs
    if [[ -s "$SCAN_TMP/turboprint-custom-pagesizes.txt" ]]; then
        cp "$SCAN_TMP/turboprint-custom-pagesizes.txt" "$OUTPUT_DIR/turboprint/" 2>/dev/null || true
        log_md "### Custom Page Sizes (from PPD files)"
        log_md '```'
        cat "$SCAN_TMP/turboprint-custom-pagesizes.txt" >> "$MD"
        log_md '```'
    fi

    echo "turboprint_present=true" >> "$MANIFEST"
    note_md "**Restore steps on new system:**"
    log_md "1. Install TurboPrint (download .tgz or .deb from turboprint.info)"
    log_md "2. \`sudo cp -r turboprint/config/. /etc/turboprint/\`"
    log_md "3. \`sudo cp turboprint/ppd/*.ppd /etc/cups/ppd/\`"
    log_md "4. \`sudo cp -r turboprint/profiles/. /usr/share/turboprint/profiles/\`"
    log_md "5. \`cp turboprint/user/dot-turboprint ~/.turboprint\`"
    log_md "6. \`sudo systemctl restart cups\`"
    log_md "7. Re-run \`sudo tpsetup --install <keyfile>\` if needed"
fi

# ── Cron ──────────────────────────────────────────────────────────────────────
section_md "16. Cron"
cp "$SCAN_TMP/crontab.txt" "$OUTPUT_DIR/" 2>/dev/null || true
log_md '```'; cat "$SCAN_TMP/crontab.txt" >> "$MD"; log_md '```'

# ── Checklist ─────────────────────────────────────────────────────────────────
cat >> "$MD" << 'CHECKLIST'

---

## Migration Checklist

### Packages
- [ ] Check `packages/` for your distro's package list
- [ ] Arch: `sudo pacman -S --needed - < packages/pacman-native.txt`
- [ ] Arch AUR: `yay -S --needed - < packages/pacman-aur.txt`
- [ ] Fedora: `xargs sudo dnf install -y < packages/dnf-native.txt`
- [ ] Debian/Ubuntu: `xargs sudo apt install -y < packages/apt-native.txt`
- [ ] Ubuntu PPAs: re-add from `packages/ppa-sources.txt` via `add-apt-repository`
- [ ] `flatpak install $(cat packages/flatpak-apps.txt)`
- [ ] Reinstall AppImages from `packages/appimages.txt`

### Configs
- [ ] Run `bash distro-plopper.sh --import --bundle <this_dir>`
- [ ] Or manually: `cp -rn configs/config-dirs/. ~/.config/`
- [ ] `cp -rn configs/dotfiles/. ~/`
- [ ] `cp -rn configs/local-share/. ~/.local/share/`
- [ ] `cp -rn flatpak/var-app/. ~/.var/app/`

### GNOME
- [ ] `dconf load / < gnome/dconf-full.ini`
- [ ] Enable extensions via Extensions app

### SSH
- [ ] Copy `~/.ssh/id_*` manually
- [ ] `chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_*`

### NFS
- [ ] Restore `/etc/exports` → `sudo exportfs -ra`
- [ ] NFS fstab lines inserted automatically; daemon-reload and mount -a run

### Fonts
- [ ] `cp -r fonts/. ~/.local/share/fonts/ && fc-cache -fv`

### Home Directories
- [ ] Run import or manually: `cp -rn homedirs/. ~/`

### /home User Directories
- [ ] Run import or manually: `sudo cp -rn user-homes/<name>/. /home/<name>/`

### TurboPrint
- [ ] Install TurboPrint on new system first
- [ ] `sudo cp -r turboprint/config/. /etc/turboprint/`
- [ ] `sudo cp turboprint/ppd/*.ppd /etc/cups/ppd/`
- [ ] `sudo cp -r turboprint/profiles/. /usr/share/turboprint/profiles/`
- [ ] `cp turboprint/user/dot-turboprint ~/.turboprint`
- [ ] `sudo systemctl restart cups`
- [ ] Verify license: `sudo tpsetup --install /etc/turboprint/<keyfile>.tpkey`

### Final
- [ ] Reboot
- [ ] `tailscale up`
- [ ] Re-pair Syncthing devices
- [ ] Verify GPU drivers
CHECKLIST

# =============================================================================
# PHASE 4: ARCHIVE
# =============================================================================
# Set ARCHIVE path now that OUTPUT_DIR is finalised
ARCHIVE="$(dirname "$OUTPUT_DIR")/distro-plopper-$TIMESTAMP.tar.gz"
header "PHASE 4: Archive..."
BUNDLE_BYTES=$(du -sb "$OUTPUT_DIR" 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
BUNDLE_SIZE=$(numfmt --to=iec "${BUNDLE_BYTES:-0}" 2>/dev/null || echo "?")
ARCHIVE_SIZE="n/a"

run_archive() {
    echo "  Bundle size: $BUNDLE_SIZE — compressing to $ARCHIVE"
    echo ""
    if command -v pv &>/dev/null; then
        tar -C "$(dirname "$OUTPUT_DIR")" -c "$(basename "$OUTPUT_DIR")" 2>/dev/null \
            | pv --size "$BUNDLE_BYTES" --progress --timer --eta --rate --bytes \
                 --name "  Archiving" \
            | gzip > "$ARCHIVE"
    else
        tar -czf "$ARCHIVE" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")" 2>/dev/null &
        TAR_PID=$!
        SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        _i=0
        while kill -0 "$TAR_PID" 2>/dev/null; do
            SPIN_CHAR="${SPIN:$(( _i % ${#SPIN} )):1}"
            CURRENT=$(du -sh "$ARCHIVE" 2>/dev/null | awk '{print $1}' || echo "...")
            printf "\r  %s  Compressing...  %s written so far" "$SPIN_CHAR" "$CURRENT"
            sleep 0.3
            _i=$(( _i + 1 ))
        done
        wait "$TAR_PID" || { echo ""; err "Compression failed — check disk space"; exit 1; }
        printf "\r  ✅  Compression complete.                              \n"
    fi
    echo ""
    ARCHIVE_SIZE=$(du -sh "$ARCHIVE" 2>/dev/null | awk '{print $1}' || echo "?")
}

case "${ARCHIVE_CHOICE:-yes}" in
    yes)
        run_archive
        ;;
    only)
        run_archive
        info "Removing bundle directory (archive-only mode)..."
        rm -rf "$OUTPUT_DIR"
        OUTPUT_DIR="(deleted — archive only)"
        ;;
    no)
        info "Skipping archive (bundle directory only)."
        ;;
esac

BUNDLE_SIZE=$(du -sh "$OUTPUT_DIR" 2>/dev/null | awk '{print $1}' || echo "n/a")

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  Export complete!${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo "  Bundle:      $OUTPUT_DIR  ($BUNDLE_SIZE)"
echo "  Archive:     $ARCHIVE  ($ARCHIVE_SIZE)"
echo "  Scan summary: $SM"
echo "  Report:      $OUTPUT_DIR/MIGRATION_REPORT.md"
echo ""
echo -e "  ${CYAN}On your new system, run:${RESET}"
echo -e "  ${BOLD}bash distro-plopper.sh --import --bundle $ARCHIVE${RESET}"
echo ""
echo -e "  ${YELLOW}Copy SSH private keys manually: ~/.ssh/id_*${RESET}"
echo ""

# End of export mode
fi # [[ "$MODE" == "export" ]]

# =============================================================================
# ██╗███╗   ███╗██████╗  ██████╗ ██████╗ ████████╗
# ██║████╗ ████║██╔══██╗██╔═══██╗██╔══██╗╚══██╔══╝
# ██║██╔████╔██║██████╔╝██║   ██║██████╔╝   ██║
# ██║██║╚██╔╝██║██╔═══╝ ██║   ██║██╔══██╗   ██║
# ██║██║ ╚═╝ ██║██║     ╚██████╔╝██║  ██║   ██║
# ╚═╝╚═╝     ╚═╝╚═╝      ╚═════╝ ╚═╝  ╚═╝   ╚═╝
# =============================================================================
if [[ "$MODE" == "import" ]]; then

if [[ -z "$BUNDLE_PATH" ]]; then
    err "Import mode requires --bundle <path>"
    echo "  Example: bash distro-plopper.sh --import --bundle ~/distro-plopper-20250101_120000"
    exit 1
fi

# ── Check for whiptail ────────────────────────────────────────────────────────
USE_TUI=true
command -v whiptail &>/dev/null || USE_TUI=false
[[ "$DRY_RUN" == true ]] && USE_TUI=false   # dry run stays text-only

# ── Resolve bundle ────────────────────────────────────────────────────────────
header "PHASE 1: Locating bundle..."
BUNDLE="$BUNDLE_PATH"

if [[ "$BUNDLE_PATH" == *.tar.gz ]]; then
    [[ ! -f "$BUNDLE_PATH" ]] && { err "Archive not found: $BUNDLE_PATH"; exit 1; }
    info "Extracting archive: $BUNDLE_PATH"
    EXTRACT_DIR=$(mktemp -d)
    trap '_pause_if_fm; rm -rf "$EXTRACT_DIR"' EXIT
    if command -v pv &>/dev/null; then
        ARCHIVE_BYTES=$(du -sb "$BUNDLE_PATH" | awk '{print $1}')
        pv --size "$ARCHIVE_BYTES" --progress --timer --eta --name "  Extracting" "$BUNDLE_PATH" \
            | tar -xz -C "$EXTRACT_DIR"
    else
        tar -xzf "$BUNDLE_PATH" -C "$EXTRACT_DIR" &
        TAR_PID=$!
        SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        _i=0
        while kill -0 "$TAR_PID" 2>/dev/null; do
            printf "\r  ${SPIN:$(( _i % ${#SPIN} )):1}  Extracting..."
            sleep 0.3
            _i=$(( _i + 1 ))
        done
        wait "$TAR_PID"
        printf "\r  ✅  Extraction complete.          \n"
    fi
    BUNDLE=$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
    ok "Extracted to: $BUNDLE"
elif [[ -d "$BUNDLE_PATH" ]]; then
    ok "Using bundle directory: $BUNDLE"
else
    err "Bundle not found: $BUNDLE_PATH"; exit 1
fi

# ── Read manifest ─────────────────────────────────────────────────────────────
MANIFEST="$BUNDLE/plopper-manifest.txt"
[[ ! -f "$MANIFEST" ]] && warn "No manifest found — proceeding with directory detection."

get_manifest() {
    local key="$1" default="${2:-}"
    [[ -f "$MANIFEST" ]] && grep "^${key}=" "$MANIFEST" 2>/dev/null | cut -d= -f2- || echo "$default"
}

# ── Import log ────────────────────────────────────────────────────────────────
if [[ -n "$IMPORT_OUTPUT_DIR" ]]; then
    mkdir -p "$IMPORT_OUTPUT_DIR"
    IMPORT_LOG="$IMPORT_OUTPUT_DIR/distro-plopper-import-$TIMESTAMP.log"
else
    IMPORT_LOG="$(dirname "$BUNDLE_PATH")/distro-plopper-import-$TIMESTAMP.log"
fi
echo "distro-plopper import log — $(date)" > "$IMPORT_LOG"
log_import() { echo "$*" >> "$IMPORT_LOG"; }

# ── Helper: copy with dry-run awareness ───────────────────────────────────────
do_copy() {
    local src="$1" dest="$2" mode="${3:-}"
    [[ "$DRY_RUN" == true ]] && { info "[DRY RUN] would copy: $src → $dest"; return; }
    mkdir -p "$dest"
    [[ "$mode" == "--file" ]] && cp -n "$src" "$dest" 2>/dev/null || cp -rn "$src" "$dest" 2>/dev/null || true
}

# ── Read bundle contents for display ─────────────────────────────────────────
# Read package manager info from manifest
SRC_PKG_MANAGER=$(get_manifest "pkg_manager" "pacman")
SRC_PKG_FAMILY=$(get_manifest "pkg_family" "arch")
SRC_PKG_SUBFAMILY=$(get_manifest "pkg_subfamily" "")
# Determine install commands for the CURRENT (target) system
detect_distro  # re-run to get current system pkg manager
SAME_FAMILY=false
[[ "$PKG_FAMILY" == "$SRC_PKG_FAMILY" ]] && SAME_FAMILY=true

# Prefer new-style apps.txt; fall back to old-style native file for older bundles
PKG_INSTALL_FILE=""
PKG_INSTALL_OLD_FORMAT=false
if [[ -f "$BUNDLE/packages/apps.txt" ]]; then
    PKG_INSTALL_FILE="$BUNDLE/packages/apps.txt"
else
    SRC_PKG_NATIVE_FILE=$(get_manifest "pkg_native_file" "pacman-native.txt")
    [[ -f "$BUNDLE/packages/$SRC_PKG_NATIVE_FILE" ]] && PKG_INSTALL_FILE="$BUNDLE/packages/$SRC_PKG_NATIVE_FILE"
    PKG_INSTALL_OLD_FORMAT=true
fi
NATIVE_COUNT=0
[[ -n "$PKG_INSTALL_FILE" ]] && NATIVE_COUNT=$(wc -l < "$PKG_INSTALL_FILE")
AUR_COUNT=0
SRC_PKG_FOREIGN_FILE=$(get_manifest "pkg_foreign_file" "${SRC_PKG_MANAGER}-foreign.txt")
[[ -f "$BUNDLE/packages/$SRC_PKG_FOREIGN_FILE" ]] && AUR_COUNT=$(wc -l < "$BUNDLE/packages/$SRC_PKG_FOREIGN_FILE")
FLATPAK_COUNT=0; [[ -f "$BUNDLE/packages/flatpak-apps.txt"  ]] && FLATPAK_COUNT=$(wc -l < "$BUNDLE/packages/flatpak-apps.txt")
APPIMAGE_COUNT=0;[[ -f "$BUNDLE/packages/appimages.txt"     ]] && APPIMAGE_COUNT=$(wc -l < "$BUNDLE/packages/appimages.txt")

HAS_CONFIGS=$( [[ -d "$BUNDLE/configs/config-dirs" ]] && echo true || echo false)
HAS_DOTFILES=$([[ -d "$BUNDLE/configs/dotfiles"    ]] && echo true || echo false)
HAS_LOCAL=$(   [[ -d "$BUNDLE/configs/local-share" ]] && echo true || echo false)
HAS_FLATPAK=$( [[ -d "$BUNDLE/flatpak/var-app"    ]] && echo true || echo false)
HAS_BROWSERS=$([[ -d "$BUNDLE/browsers"            ]] && echo true || echo false)
HAS_GNOME=$(   [[ -f "$BUNDLE/gnome/dconf-full.ini" ]] && echo true || echo false)
HAS_SSH=$(     [[ -f "$BUNDLE/ssh/config"          ]] && echo true || echo false)
HAS_FONTS=$(   [[ -d "$BUNDLE/fonts"               ]] && echo true || echo false)
HAS_STEAM=$(    [[ -d "$BUNDLE/steam"               ]] && echo true || echo false)
HAS_HOMEDIRS=$(   [[ -d "$BUNDLE/homedirs"           ]] && echo true || echo false)
HAS_USERHOMES=$(  [[ -d "$BUNDLE/user-homes"        ]] && echo true || echo false)
NFS_EXP=$(get_manifest "nfs_exports" "false")
NFS_MNT=$(get_manifest "nfs_mounts"  "false")
# Support both new bundles (fstab-nfs-lines) and old bundles (full fstab)
NFS_FSTAB_FILE=""
[[ -f "$BUNDLE/nfs/fstab-nfs-lines" ]] && NFS_FSTAB_FILE="$BUNDLE/nfs/fstab-nfs-lines"
[[ -z "$NFS_FSTAB_FILE" && -f "$BUNDLE/nfs/fstab" ]] && NFS_FSTAB_FILE="$BUNDLE/nfs/fstab"

SOURCE_OS=$(grep "^# Source OS:" "$MANIFEST" 2>/dev/null | cut -d: -f2- | xargs || echo "unknown")
SOURCE_HOST=$(grep "^# Source host:" "$MANIFEST" 2>/dev/null | cut -d: -f2- | xargs || echo "unknown")

# ═════════════════════════════════════════════════════════════════════════════
# TUI MODE (whiptail)
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$USE_TUI" == true ]]; then

TERM_H=$(tput lines); TERM_W=$(tput cols)
BOX_H=$(( TERM_H - 4 )); BOX_W=$(( TERM_W - 8 ))
[[ $BOX_H -lt 20 ]] && BOX_H=20
[[ $BOX_W -lt 70 ]] && BOX_W=70

# ── Welcome screen ────────────────────────────────────────────────────────────
# ── Screen 1: Bundle summary ─────────────────────────────────────────────────
TP_IN_BUNDLE=$( [[ -d "$BUNDLE/turboprint" ]] && echo "yes" || echo "no" )
NFS_IN_BUNDLE=$( [[ "$NFS_MNT" == "true" || "$NFS_EXP" == "true" ]] && echo "yes" || echo "no" )

whiptail --title "🪣  Distro Plopper — Import" \
  --msgbox "\
Bundle found and loaded.

  Source OS:    $SOURCE_OS
  Source host:  $SOURCE_HOST
  Bundle path:  $BUNDLE

Contents:
  • $NATIVE_COUNT ${SRC_PKG_MANAGER} packages  ($AUR_COUNT foreign/AUR)
  • $FLATPAK_COUNT Flatpak apps
  • $APPIMAGE_COUNT AppImages (manual copy required)
  • Configs, dotfiles, ~/.local/share
  • Browsers, GNOME, SSH, Fonts, Steam
  • TurboPrint: $TP_IN_BUNDLE
  • NFS mounts: $NFS_IN_BUNDLE

Press OK to review the pre-flight checklist." \
  $BOX_H $BOX_W

# ── Screen 2: Pre-flight checklist ───────────────────────────────────────────
# Build checklist dynamically based on what's in the bundle

PREFLIGHT_MSG="Before the import runs, please confirm the following.\n\nYou can come back and re-run at any time — configs use\nno-overwrite mode so nothing will be double-applied.\n\n"
PREFLIGHT_MSG+="─────────────────────────────────────────────\n"
PREFLIGHT_MSG+="REQUIRED BEFORE CONTINUING:\n"
PREFLIGHT_MSG+="─────────────────────────────────────────────\n\n"
PREFLIGHT_MSG+="□  You are connected to the internet\n"
PREFLIGHT_MSG+="□  You have sudo / root access on this machine\n"

if [[ "$AUR_COUNT" -gt 0 ]] && [[ "$PKG_FAMILY" == "arch" ]]; then
    if [[ -z "$AUR_HELPER" ]]; then
        PREFLIGHT_MSG+="□  ⚠ Install an AUR helper FIRST:\n"
        PREFLIGHT_MSG+="      sudo pacman -S --needed git base-devel\n"
        PREFLIGHT_MSG+="      git clone https://aur.archlinux.org/yay.git\n"
        PREFLIGHT_MSG+="      cd yay && makepkg -si\n"
    else
        PREFLIGHT_MSG+="✓  AUR helper found: $AUR_HELPER\n"
    fi
fi

if [[ "$FLATPAK_COUNT" -gt 0 ]]; then
    if command -v flatpak &>/dev/null; then
        PREFLIGHT_MSG+="✓  Flatpak is installed\n"
    else
        PREFLIGHT_MSG+="□  ⚠ Install Flatpak first:\n"
        case "$PKG_FAMILY" in
            arch)   PREFLIGHT_MSG+="      sudo pacman -S flatpak\n" ;;
            fedora) PREFLIGHT_MSG+="      sudo dnf install flatpak\n" ;;
            debian) PREFLIGHT_MSG+="      sudo apt install flatpak\n" ;;
        esac
        PREFLIGHT_MSG+="      flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo\n"
    fi
fi

if [[ "$TP_IN_BUNDLE" == "yes" ]]; then
    PREFLIGHT_MSG+="\n─────────────────────────────────────────────\n"
    PREFLIGHT_MSG+="TURBOPRINT (important — install BEFORE import):\n"
    PREFLIGHT_MSG+="─────────────────────────────────────────────\n"
    PREFLIGHT_MSG+="□  Download TurboPrint from turboprint.info\n"
    PREFLIGHT_MSG+="□  Install it: sudo ./setup  (TGZ) or  sudo dpkg -i *.deb\n"
    PREFLIGHT_MSG+="□  Have your .tpkey license file accessible\n"
    PREFLIGHT_MSG+="□  Your printer is connected and powered on\n"
    if [[ -f "$BUNDLE/turboprint/config/"*.tpkey ]] 2>/dev/null; then
        PREFLIGHT_MSG+="✓  License key found in bundle\n"
    else
        PREFLIGHT_MSG+="□  ⚠ No .tpkey found in bundle — locate your key file\n"
    fi
fi

if [[ -d "$BUNDLE/displaycal" ]]; then
    PREFLIGHT_MSG+="\n─────────────────────────────────────────────\n"
    PREFLIGHT_MSG+="DISPLAYCAL / MONITOR PROFILES:\n"
    PREFLIGHT_MSG+="─────────────────────────────────────────────\n"
    PREFLIGHT_MSG+="□  Is this the SAME MONITOR as the source system?\n"
    PREFLIGHT_MSG+="   Same monitor → profile loads automatically\n"
    PREFLIGHT_MSG+="   Different monitor → re-run DisplayCAL calibration\n"
    PREFLIGHT_MSG+="□  Ensure colord service is running: systemctl status colord\n"
fi

if [[ "$NFS_IN_BUNDLE" == "yes" ]]; then
    PREFLIGHT_MSG+="\n─────────────────────────────────────────────\n"
    PREFLIGHT_MSG+="NFS:\n"
    PREFLIGHT_MSG+="─────────────────────────────────────────────\n"
    PREFLIGHT_MSG+="□  NFS server(s) are reachable on the network\n"
    PREFLIGHT_MSG+="   (NFS fstab lines will be inserted automatically)\n"
fi

PREFLIGHT_MSG+="\n─────────────────────────────────────────────\n"
PREFLIGHT_MSG+="AFTER IMPORT — MANUAL STEPS STILL NEEDED:\n"
PREFLIGHT_MSG+="─────────────────────────────────────────────\n"
PREFLIGHT_MSG+="□  Copy SSH private keys manually\n"
PREFLIGHT_MSG+="□  Re-authenticate Tailscale: tailscale up\n"
PREFLIGHT_MSG+="□  Re-pair Syncthing devices\n"
PREFLIGHT_MSG+="□  Enable GNOME extensions via Extensions app\n"
PREFLIGHT_MSG+="□  Reboot (required — services won't pick up until restart)\n"
[[ "$HAS_USERHOMES" == true ]] && \
    PREFLIGHT_MSG+="\n⚠  /home user directory restore requires sudo\n"

whiptail --title "Pre-flight Checklist" \
  --msgbox "$PREFLIGHT_MSG" \
  $BOX_H $BOX_W

# ── Screen 3: Confirm order of events ────────────────────────────────────────
whiptail --title "Import — Order of Events" \
  --msgbox "\
The import runs in this order to ensure apps exist
before their configs are restored:

  Stage 1 — Packages & apps
    1a. Native packages (${PKG_MANAGER})
    1b. AUR / foreign packages
    1c. PPAs / external repos  (Ubuntu/Debian)
    1d. Flatpak apps
    1e. TurboPrint config      (if in bundle)

  Stage 2 — Configs & data
    2a. App configs  (~/.config)
    2b. Home dotfiles
    2c. ~/.local/share data
    2d. Flatpak app data  (~/.var/app)
    2e. Browser profiles
    2f. GNOME settings & extensions
    2g. SSH config & known_hosts
    2h. Fonts
    2i. Steam config & userdata
    2j. XDG home dirs (Documents, Downloads etc.)
    2k. /home user directories  (sudo)
    2l. CUPS printers
    2m. DisplayCAL / ArgyllCMS profiles

  Stage 3 — System
    3a. NFS  (shown for manual action)
    3b. Summary & remaining manual steps

Press OK to begin." \
  $BOX_H $BOX_W

# ═══════════════════════════════════════════════════════
# STAGE 1: PACKAGES
# ═══════════════════════════════════════════════════════

# ── AUR helper check ──────────────────────────────────────────────────────────
AUR_HELPER=""
command -v yay  &>/dev/null && AUR_HELPER="yay"  || true
command -v paru &>/dev/null && AUR_HELPER="paru" || true

# ── Native packages ───────────────────────────────────────────────────────────
INSTALL_NATIVE=false
CROSS_DISTRO_WARNING=""
[[ "$SAME_FAMILY" == false ]] && CROSS_DISTRO_WARNING="
NOTE: Source was ${SRC_PKG_FAMILY} (${SRC_PKG_MANAGER}), this system is
${PKG_FAMILY} (${PKG_MANAGER}). App names are usually the same across distros
but some may not exist — failures will be skipped with a warning."

if [[ "$IMP_NO_PACKAGES" == false ]] && [[ -n "$PKG_INSTALL_FILE" ]]; then
    OLD_NOTE=""
    [[ "$PKG_INSTALL_OLD_FORMAT" == true ]] && OLD_NOTE="
(Legacy bundle — using full package list. Some packages may not exist on this distro.)"
    whiptail --title "Stage 1 of 2: Packages ($NATIVE_COUNT apps)" \
      --yesno "\
$NATIVE_COUNT apps from the source system.${CROSS_DISTRO_WARNING}${OLD_NOTE}

Will install using: ${PKG_MANAGER}
Already-installed packages will be skipped.
This may take a while depending on how many need downloading.

Install packages?" \
      $BOX_H $BOX_W && INSTALL_NATIVE=true || true
fi

declare -a SELECTED_AUR=()  # retained for summary line compatibility

# ── Flatpak checklist ─────────────────────────────────────────────────────────
declare -a SELECTED_FLATPAK=()
if [[ "$IMP_NO_PACKAGES" == false ]] && [[ -f "$BUNDLE/packages/flatpak-full.txt" ]] && [[ "$FLATPAK_COUNT" -gt 0 ]]; then
    if ! command -v flatpak &>/dev/null; then
        whiptail --title "Flatpak — Not Installed" \
          --msgbox "Flatpak is not installed on this system. Skipping $FLATPAK_COUNT Flatpak apps.
Install flatpak first, then re-run the import." \
          12 $BOX_W
    else
        CHECKLIST_ARGS=()
        while read -r appid name version origin; do
            LABEL="${name:-$appid} (${version:-?}) [${origin:-?}]"
            CHECKLIST_ARGS+=("$appid" "$LABEL" "ON")
        done < "$BUNDLE/packages/flatpak-full.txt"

        FLATPAK_CHOICES=$(whiptail --title "Stage 1 of 2: Flatpak Apps ($FLATPAK_COUNT found)" \
          --checklist \
"Select Flatpak apps to install.
All are pre-selected. Uncheck any you don't want.
Space = toggle  |  Tab = move to OK/Cancel  |  Enter = confirm  |  Esc = cancel" \
          $BOX_H $BOX_W $(( BOX_H - 10 )) \
          "${CHECKLIST_ARGS[@]}" \
          3>&1 1>&2 2>&3) || true

        if [[ -n "$FLATPAK_CHOICES" ]]; then
            read -ra SELECTED_FLATPAK <<< "$FLATPAK_CHOICES"
            SELECTED_FLATPAK=("${SELECTED_FLATPAK[@]//\"/}")
        fi
    fi
fi

# ── AppImages notice ──────────────────────────────────────────────────────────
if [[ "$APPIMAGE_COUNT" -gt 0 ]]; then
    whiptail --title "AppImages ($APPIMAGE_COUNT found)" \
      --msgbox "\
AppImages cannot be installed automatically — they are standalone files
that need to be copied manually.

Your AppImages from the old system:
$(cat "$BUNDLE/packages/appimages.txt")

Copy these files to wherever you keep them (e.g. ~/Applications/)
and make them executable with: chmod +x *.AppImage" \
      $BOX_H $BOX_W
fi

# ── Confirm package install ───────────────────────────────────────────────────
SUMMARY_LINES=""
[[ "$INSTALL_NATIVE" == true ]] && SUMMARY_LINES+="  • $NATIVE_COUNT native pacman packages\n"
[[ "${#SELECTED_AUR[@]}" -gt 0 ]] && SUMMARY_LINES+="  • ${#SELECTED_AUR[@]} AUR packages\n"
[[ "${#SELECTED_FLATPAK[@]}" -gt 0 ]] && SUMMARY_LINES+="  • ${#SELECTED_FLATPAK[@]} Flatpak apps\n"
[[ -z "$SUMMARY_LINES" ]] && SUMMARY_LINES="  • Nothing selected\n"

whiptail --title "Confirm Package Installation" \
  --yesno "Ready to install:
$SUMMARY_LINES
This will run in the background with output shown in the terminal.
Configs will be restored AFTER all packages are installed.

Proceed?" \
  15 $BOX_W && DO_INSTALL=true || DO_INSTALL=false

# ── Run installs ──────────────────────────────────────────────────────────────
if [[ "$DO_INSTALL" == true ]]; then

    if [[ "$INSTALL_NATIVE" == true ]]; then
        echo ""
        header "Installing packages via ${PKG_MANAGER} ($NATIVE_COUNT)..."
        case "$PKG_FAMILY" in
            arch)
                # Capture packages pacman can't find (AUR), try AUR helper for those
                _PACMAN_FAILED=$(mktemp)
                sudo pacman -S --needed - < "$PKG_INSTALL_FILE" 2>&1 \
                    | tee -a "$IMPORT_LOG" \
                    | grep "^error: target not found:" \
                    | sed 's/error: target not found: //' > "$_PACMAN_FAILED" || true
                if [[ -s "$_PACMAN_FAILED" ]] && [[ -n "$AUR_HELPER" ]]; then
                    warn "$(wc -l < "$_PACMAN_FAILED") packages not in official repos — trying $AUR_HELPER..."
                    $AUR_HELPER -S --needed - < "$_PACMAN_FAILED" 2>&1 | tee -a "$IMPORT_LOG" || warn "Some AUR packages failed"
                elif [[ -s "$_PACMAN_FAILED" ]]; then
                    warn "$(wc -l < "$_PACMAN_FAILED") packages not found — install an AUR helper (yay/paru) and retry"
                    cat "$_PACMAN_FAILED"
                fi
                rm -f "$_PACMAN_FAILED"
                ;;
            fedora) xargs sudo dnf install -y < "$PKG_INSTALL_FILE" 2>&1 | tee -a "$IMPORT_LOG" || warn "Some packages failed" ;;
            debian) xargs sudo apt install -y < "$PKG_INSTALL_FILE" 2>&1 | tee -a "$IMPORT_LOG" || warn "Some packages failed" ;;
            suse)   xargs sudo zypper install -y < "$PKG_INSTALL_FILE" 2>&1 | tee -a "$IMPORT_LOG" || warn "Some packages failed" ;;
            *)      warn "Unknown package manager — install manually from $PKG_INSTALL_FILE" ;;
        esac
        ok "Packages done"
    fi

    if [[ "${#SELECTED_AUR[@]}" -gt 0 ]] && [[ "$PKG_FAMILY" == "arch" ]]; then
        echo ""
        header "Installing AUR packages (${#SELECTED_AUR[@]})..."
        printf '%s\n' "${SELECTED_AUR[@]}" | $AUR_HELPER -S --needed - 2>&1 | tee -a "$IMPORT_LOG" || warn "Some AUR packages failed"
        ok "AUR packages done"
    fi

    # Ubuntu/Debian: offer to re-add PPAs before package install
    if [[ "$PKG_FAMILY" == "debian" ]] && [[ -f "$BUNDLE/packages/ppa-sources.txt" ]] && [[ -s "$BUNDLE/packages/ppa-sources.txt" ]]; then
        PPA_COUNT=$(wc -l < "$BUNDLE/packages/ppa-sources.txt")
        if whiptail --title "PPAs / External Repositories ($PPA_COUNT found)" \
          --yesno "The source system had $PPA_COUNT PPAs or external repositories.
Re-adding them ensures you can install packages that came from those sources.

PPAs found:
$(cat "$BUNDLE/packages/ppa-sources.txt")

Add these PPAs now? (requires internet connection)" \
          $BOX_H $BOX_W; then
            echo ""
            header "Adding PPAs..."
            if command -v add-apt-repository &>/dev/null; then
                while read -r ppa; do
                    [[ -z "$ppa" ]] && continue
                    info "Adding: $ppa"
                    sudo add-apt-repository -y "$ppa" 2>&1 | tee -a "$IMPORT_LOG" || warn "Failed to add: $ppa"
                done < "$BUNDLE/packages/ppa-sources.txt"
                sudo apt update 2>&1 | tee -a "$IMPORT_LOG" || true
                ok "PPAs added and apt updated"
            else
                warn "add-apt-repository not found — install software-properties-common first"
                warn "Then add PPAs from: $BUNDLE/packages/ppa-sources.txt"
            fi
        fi
    fi

    if [[ "${#SELECTED_FLATPAK[@]}" -gt 0 ]]; then
        echo ""
        header "Installing Flatpak apps (${#SELECTED_FLATPAK[@]})..."
        flatpak install --noninteractive "${SELECTED_FLATPAK[@]}" 2>&1 | tee -a "$IMPORT_LOG" || warn "Some Flatpak apps failed"
        ok "Flatpak apps done"
        info "  Log out and back in for Flatpak apps to appear in your launcher"
    fi

    whiptail --title "✅ Packages Complete" \
      --msgbox "Package installation finished.
Check the terminal output above for any errors.

Now moving to Stage 2: Restore configs and data." \
      12 $BOX_W
fi

# ═══════════════════════════════════════════════════════
# STAGE 1e: TURBOPRINT (after packages, before configs)
# ═══════════════════════════════════════════════════════
if [[ -d "$BUNDLE/turboprint" ]] && [[ "$IMP_NO_TURBOPRINT" == false ]]; then
    TP_INSTALLED=false
    [[ -d /etc/turboprint ]] && TP_INSTALLED=true

    if [[ "$USE_TUI" == true ]]; then
        if [[ "$TP_INSTALLED" == false ]]; then
            whiptail --title "⚠️  TurboPrint — Not Installed"               --msgbox "TurboPrint configuration is in the bundle but TurboPrint
is NOT installed on this system yet.

The config restore will be SKIPPED until you install it.

To install TurboPrint:
  1. Download from https://www.turboprint.info/download.html
  2. sudo ./setup  (TGZ)  or  sudo dpkg -i *.deb  (DEB)
  3. Re-run: bash distro-plopper.sh --import --bundle $BUNDLE

The bundle will still be here when you come back."               $BOX_H $BOX_W
        else
            whiptail --title "TurboPrint — Restore Config"               --yesno "TurboPrint is installed and config is in the bundle.

  • Printer configs:  $(ls "$BUNDLE/turboprint/config/" 2>/dev/null | wc -l) files
  • CUPS PPD files:   $(ls "$BUNDLE/turboprint/ppd/" 2>/dev/null | wc -l) printer queue(s)
  • ICC profiles:     $(ls "$BUNDLE/turboprint/profiles/" 2>/dev/null | wc -l) profiles
  • License key:      $( find "$BUNDLE/turboprint/config" -name "*.tpkey" 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo "not found" )
  • User settings:    $( [[ -f "$BUNDLE/turboprint/user/dot-turboprint" ]] && echo "yes" || echo "no" )

Restore TurboPrint configuration now?"               $BOX_H $BOX_W && _DO_TP_RESTORE=true || _DO_TP_RESTORE=false

            if [[ "$_DO_TP_RESTORE" == true ]]; then
                echo ""; header "Restoring TurboPrint..."
                sudo cp -r "$BUNDLE/turboprint/config/." /etc/turboprint/ 2>/dev/null || warn "Failed — try manually"
                [[ -d "$BUNDLE/turboprint/ppd" ]]      && sudo cp "$BUNDLE/turboprint/ppd/"*.ppd /etc/cups/ppd/ 2>/dev/null || true
                [[ -d "$BUNDLE/turboprint/profiles" ]] && sudo cp -r "$BUNDLE/turboprint/profiles/." /usr/share/turboprint/profiles/ 2>/dev/null || true
                [[ -f "$BUNDLE/turboprint/user/dot-turboprint" ]] && cp "$BUNDLE/turboprint/user/dot-turboprint" "$HOME/.turboprint" 2>/dev/null || true
                sudo systemctl restart cups 2>/dev/null || true
                ok "TurboPrint restored"
                log_import "RESTORED: TurboPrint"

                TPKEY_FOUND=$(find /etc/turboprint -name "*.tpkey" 2>/dev/null | head -1 || true)
                whiptail --title "TurboPrint — License"                   --msgbox "TurboPrint config restored and CUPS restarted.

License key status:
  $( [[ -n "$TPKEY_FOUND" ]] && echo "✅ Key found: $(basename "$TPKEY_FOUND")" || echo "⚠️  No .tpkey found — locate and run:" )
  $( [[ -z "$TPKEY_FOUND" ]] && echo "  sudo tpsetup --install <keyfile>.tpkey" || true )

Verify printer queues:
  xtpsetup        (GUI)
  tpsetup --list  (command line)

If printouts show a watermark, the license needs re-applying."                   $BOX_H $BOX_W
            fi
        fi
    else
        # Text mode TurboPrint restore
        if [[ "$TP_INSTALLED" == true ]]; then
            step "TurboPrint config..."
            if [[ "$DRY_RUN" == false ]]; then
                sudo cp -r "$BUNDLE/turboprint/config/." /etc/turboprint/ 2>/dev/null || warn "Failed to copy /etc/turboprint"
                [[ -d "$BUNDLE/turboprint/ppd" ]]      && sudo cp "$BUNDLE/turboprint/ppd/"*.ppd /etc/cups/ppd/ 2>/dev/null || true
                [[ -d "$BUNDLE/turboprint/profiles" ]] && sudo cp -r "$BUNDLE/turboprint/profiles/." /usr/share/turboprint/profiles/ 2>/dev/null || true
                [[ -f "$BUNDLE/turboprint/user/dot-turboprint" ]] && cp "$BUNDLE/turboprint/user/dot-turboprint" "$HOME/.turboprint" 2>/dev/null || true
                sudo systemctl restart cups 2>/dev/null || true
                ok "TurboPrint restored"
                log_import "RESTORED: TurboPrint"
            else
                info "[DRY RUN] would restore TurboPrint"
            fi
            warn "Verify license: sudo tpsetup --install /etc/turboprint/<keyfile>.tpkey"
        else
            warn "TurboPrint not installed — skipping config restore. Install first and re-run."
        fi
    fi
fi

# ═══════════════════════════════════════════════════════
# STAGE 2: CONFIGS & DATA
# ═══════════════════════════════════════════════════════

# Build checklist from what's actually in the bundle
CONFIG_OPTS=()
[[ "$HAS_CONFIGS"  == true ]] && CONFIG_OPTS+=("configs"   "~/.config app directories ($(du -sh "$BUNDLE/configs/config-dirs" 2>/dev/null | awk '{print $1}'))" "ON")
[[ "$HAS_DOTFILES" == true ]] && CONFIG_OPTS+=("dotfiles"  "Home dotfiles (.bashrc, .zshrc, .gitconfig etc.)" "ON")
[[ "$HAS_LOCAL"    == true ]] && CONFIG_OPTS+=("localshare" "~/.local/share app data ($(du -sh "$BUNDLE/configs/local-share" 2>/dev/null | awk '{print $1}'))" "ON")
[[ "$HAS_FLATPAK"  == true ]] && CONFIG_OPTS+=("flatpakdata" "Flatpak app data ~/.var/app ($(du -sh "$BUNDLE/flatpak/var-app" 2>/dev/null | awk '{print $1}'))" "ON")
[[ "$HAS_BROWSERS" == true ]] && CONFIG_OPTS+=("browsers"  "Browser profiles ($(du -sh "$BUNDLE/browsers" 2>/dev/null | awk '{print $1}'))" "ON")
[[ "$HAS_GNOME"    == true ]] && CONFIG_OPTS+=("gnome"     "GNOME settings (dconf + extensions)" "ON")
[[ "$HAS_SSH"      == true ]] && CONFIG_OPTS+=("ssh"       "SSH config & known_hosts (keys NOT copied)" "ON")
[[ "$HAS_FONTS"    == true ]] && CONFIG_OPTS+=("fonts"     "User fonts ($(du -sh "$BUNDLE/fonts" 2>/dev/null | awk '{print $1}'))" "ON")
[[ "$HAS_STEAM"    == true ]] && CONFIG_OPTS+=("steam"     "Steam config & userdata (no game files)" "ON")
[[ "$HAS_HOMEDIRS"   == true ]] && CONFIG_OPTS+=("homedirs"   "XDG home dirs — Documents, Downloads, Pictures etc. ($(du -sh "$BUNDLE/homedirs" 2>/dev/null | awk '{print $1}'))" "ON")
[[ "$HAS_USERHOMES"  == true ]] && CONFIG_OPTS+=("userhomes"  "/home user directories ($(du -sh "$BUNDLE/user-homes" 2>/dev/null | awk '{print $1}')) — requires sudo" "ON")

RESTORE_CHOICES=""
if [[ "${#CONFIG_OPTS[@]}" -gt 0 ]]; then
    RESTORE_CHOICES=$(whiptail --title "Stage 2 of 2: Select What to Restore" \
      --checklist \
"Everything is pre-selected. Uncheck anything you want to skip.
Configs are copied with no-overwrite — existing files are kept.
Space = toggle  |  Tab = move to OK/Cancel  |  Enter = confirm  |  Esc = cancel" \
      $BOX_H $BOX_W $(( BOX_H - 10 )) \
      "${CONFIG_OPTS[@]}" \
      3>&1 1>&2 2>&3) || true
else
    whiptail --title "Nothing to Restore" \
      --msgbox "No restorable content was found in the bundle." \
      10 $BOX_W
fi

# Parse selections
RESTORE_CONFIGS=false;    [[ "$RESTORE_CHOICES" == *'"configs"'*     ]] && RESTORE_CONFIGS=true
RESTORE_DOTFILES=false;   [[ "$RESTORE_CHOICES" == *'"dotfiles"'*    ]] && RESTORE_DOTFILES=true
RESTORE_LOCAL=false;      [[ "$RESTORE_CHOICES" == *'"localshare"'*  ]] && RESTORE_LOCAL=true
RESTORE_FLATPAK=false;    [[ "$RESTORE_CHOICES" == *'"flatpakdata"'* ]] && RESTORE_FLATPAK=true
RESTORE_BROWSERS=false;   [[ "$RESTORE_CHOICES" == *'"browsers"'*    ]] && RESTORE_BROWSERS=true
RESTORE_GNOME=false;      [[ "$RESTORE_CHOICES" == *'"gnome"'*       ]] && RESTORE_GNOME=true
RESTORE_SSH=false;        [[ "$RESTORE_CHOICES" == *'"ssh"'*         ]] && RESTORE_SSH=true
RESTORE_FONTS=false;      [[ "$RESTORE_CHOICES" == *'"fonts"'*       ]] && RESTORE_FONTS=true
RESTORE_STEAM=false;      [[ "$RESTORE_CHOICES" == *'"steam"'*       ]] && RESTORE_STEAM=true
RESTORE_HOMEDIRS=false;   [[ "$RESTORE_CHOICES" == *'"homedirs"'*    ]] && RESTORE_HOMEDIRS=true
RESTORE_USERHOMES=false;  [[ "$RESTORE_CHOICES" == *'"userhomes"'*   ]] && RESTORE_USERHOMES=true

# ── Run restores ──────────────────────────────────────────────────────────────
echo ""
header "PHASE 3: Restoring configs..."

if [[ "$RESTORE_CONFIGS" == true ]]; then
    step "~/.config..."; do_copy "$BUNDLE/configs/config-dirs/." "$HOME/.config"; ok "~/.config restored"; log_import "RESTORED: ~/.config"
fi
if [[ "$RESTORE_DOTFILES" == true ]]; then
    step "Dotfiles..."; do_copy "$BUNDLE/configs/dotfiles/." "$HOME"; ok "Dotfiles restored"; log_import "RESTORED: dotfiles"
fi
if [[ "$RESTORE_LOCAL" == true ]]; then
    step "~/.local/share..."; do_copy "$BUNDLE/configs/local-share/." "$HOME/.local/share"; ok "~/.local/share restored"; log_import "RESTORED: ~/.local/share"
fi
if [[ "$RESTORE_FLATPAK" == true ]]; then
    step "Flatpak data..."; do_copy "$BUNDLE/flatpak/var-app/." "$HOME/.var/app"; ok "Flatpak data restored"; log_import "RESTORED: ~/.var/app"
fi

if [[ "$RESTORE_BROWSERS" == true ]]; then
    step "Browser profiles..."
    if [[ -f "$MANIFEST" ]] && grep -q "^browser:" "$MANIFEST"; then
        grep "^browser:" "$MANIFEST" | while IFS=: read -r _ name orig_dir bundle_subdir; do
            BUNDLE_SRC="$BUNDLE/$bundle_subdir"
            [[ -d "$BUNDLE_SRC" ]] && do_copy "$BUNDLE_SRC/." "$(dirname "$orig_dir")" && ok "$name restored" && log_import "RESTORED: browser $name"
        done
    fi
fi

if [[ "$RESTORE_GNOME" == true ]]; then
    step "GNOME extensions..."
    [[ -d "$BUNDLE/gnome/extensions-backup" ]] && do_copy "$BUNDLE/gnome/extensions-backup/." "$HOME/.local/share/gnome-shell/extensions"
    step "dconf settings..."
    if [[ -f "$BUNDLE/gnome/dconf-full.ini" ]] && command -v dconf &>/dev/null; then
        dconf load / < "$BUNDLE/gnome/dconf-full.ini" && ok "dconf loaded" && log_import "RESTORED: dconf"
    fi
fi

if [[ "$RESTORE_SSH" == true ]]; then
    step "SSH..."
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    [[ -f "$BUNDLE/ssh/config" ]]          && do_copy "$BUNDLE/ssh/config"          "$HOME/.ssh" --file
    [[ -f "$BUNDLE/ssh/known_hosts" ]]     && do_copy "$BUNDLE/ssh/known_hosts"     "$HOME/.ssh" --file
    [[ -f "$BUNDLE/ssh/authorized_keys" ]] && do_copy "$BUNDLE/ssh/authorized_keys" "$HOME/.ssh" --file
    ok "SSH config restored"; log_import "RESTORED: SSH"
fi

if [[ "$RESTORE_FONTS" == true ]]; then
    step "Fonts..."
    mkdir -p "$HOME/.local/share/fonts"
    for d in "$BUNDLE/fonts"/*/; do cp -rn "$d/." "$HOME/.local/share/fonts/" 2>/dev/null || true; done
    fc-cache -fv > /dev/null 2>&1
    ok "Fonts restored"; log_import "RESTORED: fonts"
fi

if [[ "$RESTORE_STEAM" == true ]]; then
    step "Steam config..."
    STEAM_DEST="$HOME/.local/share/Steam"
    mkdir -p "$STEAM_DEST"
    for d in "$BUNDLE/steam"/*/; do
        NAME=$(basename "$d"); [[ "$NAME" == "dot-steam" ]] && continue
        do_copy "$d" "$STEAM_DEST/$NAME"; ok "Steam: $NAME"
    done
    find "$BUNDLE/steam" -maxdepth 1 -name "*.vdf" -exec cp -n {} "$STEAM_DEST/" \; 2>/dev/null || true
    log_import "RESTORED: Steam"
fi

if [[ "$RESTORE_HOMEDIRS" == true ]]; then
    step "XDG home directories..."
    grep "^homedir:" "$MANIFEST" 2>/dev/null | while IFS=: read -r _ xdg orig_dir bundle_subdir; do
        BUNDLE_SRC="$BUNDLE/$bundle_subdir"
        DEST_PARENT=$(dirname "$orig_dir")
        [[ -d "$BUNDLE_SRC" ]] && do_copy "$BUNDLE_SRC" "$DEST_PARENT" && ok "homedirs: $xdg (→ $orig_dir)" && log_import "RESTORED: homedir $xdg"
    done
fi

if [[ "$RESTORE_USERHOMES" == true ]]; then
    step "/home user directories..."
    grep "^userhome:" "$MANIFEST" 2>/dev/null | while IFS=: read -r _ name orig_dir bundle_subdir; do
        BUNDLE_SRC="$BUNDLE/$bundle_subdir"
        if [[ -d "$BUNDLE_SRC" ]]; then
            [[ "$DRY_RUN" == true ]] && { info "[DRY RUN] would sudo cp -rn $BUNDLE_SRC/. $orig_dir"; continue; }
            sudo mkdir -p "$orig_dir"
            sudo cp -rn "$BUNDLE_SRC/." "$orig_dir/" 2>/dev/null || warn "Some files may not have copied for $name"
            ok "/home/$name restored"; log_import "RESTORED: /home/$name"
        fi
    done
fi

# ── CUPS restore ─────────────────────────────────────────────────────────────
if [[ "$IMP_NO_CUPS" == false ]] && [[ -d "$BUNDLE/cups" ]] && [[ -n "$(ls "$BUNDLE/cups/" 2>/dev/null)" ]]; then
    CUPS_Q=$(grep -c "^<Printer " "$BUNDLE/cups/printers.conf" 2>/dev/null || echo 0)
    step "CUPS printers ($CUPS_Q queues)..."
    if [[ "$DRY_RUN" == false ]]; then
        # printers.conf and PPDs need root
        [[ -f "$BUNDLE/cups/printers.conf" ]] && sudo cp "$BUNDLE/cups/printers.conf" /etc/cups/ 2>/dev/null || warn "printers.conf needs manual copy"
        [[ -f "$BUNDLE/cups/cupsd.conf"    ]] && sudo cp "$BUNDLE/cups/cupsd.conf"    /etc/cups/ 2>/dev/null || true
        [[ -f "$BUNDLE/cups/lpoptions"     ]] && sudo cp "$BUNDLE/cups/lpoptions"     /etc/cups/ 2>/dev/null || true
        if [[ -d "$BUNDLE/cups/ppd" ]]; then
            sudo cp "$BUNDLE/cups/ppd/"*.ppd /etc/cups/ppd/ 2>/dev/null || true
        fi
        [[ -f "$BUNDLE/cups/user-cups/lpoptions" ]] && { mkdir -p "$HOME/.cups"; cp "$BUNDLE/cups/user-cups/lpoptions" "$HOME/.cups/" 2>/dev/null || true; }
        sudo systemctl restart cups 2>/dev/null || true
        ok "CUPS config restored — verify queues at http://localhost:631"
        log_import "RESTORED: CUPS"
        if [[ "$USE_TUI" == true ]]; then
            whiptail --title "CUPS — Verify Printers"               --msgbox "CUPS printer config restored ($CUPS_Q queue(s)).

To verify everything is working:
  • Open http://localhost:631 in a browser
  • Or run: lpstat -v

USB printers: plug your printer in and CUPS should
reconnect automatically on next print job.

Network printers (IPP/socket): should work immediately
if the IP address hasn't changed."               $BOX_H $BOX_W
        else
            warn "CUPS: verify printers at http://localhost:631 or lpstat -v"
        fi
    else
        info "[DRY RUN] would restore CUPS config ($CUPS_Q queues)"
    fi
fi

# ── DisplayCAL / ArgyllCMS restore ───────────────────────────────────────────
if [[ "$IMP_NO_DISPLAYCAL" == false ]] && [[ -d "$BUNDLE/displaycal" ]] && [[ -n "$(ls "$BUNDLE/displaycal/" 2>/dev/null)" ]]; then
    step "DisplayCAL / ArgyllCMS profiles..."
    if [[ "$DRY_RUN" == false ]]; then
        # User ICC profiles
        if [[ -d "$BUNDLE/displaycal/icc-user" ]]; then
            mkdir -p "$HOME/.local/share/color"
            cp -rn "$BUNDLE/displaycal/icc-user/." "$HOME/.local/share/color/" 2>/dev/null || true
        fi
        if [[ -d "$BUNDLE/displaycal/icc-home" ]]; then
            mkdir -p "$HOME/.color"
            cp -rn "$BUNDLE/displaycal/icc-home/." "$HOME/.color/" 2>/dev/null || true
        fi
        # DisplayCAL storage (sessions, settings, profiles)
        if [[ -d "$BUNDLE/displaycal/displaycal-storage/DisplayCAL" ]]; then
            mkdir -p "$HOME/.local/share/DisplayCAL"
            cp -rn "$BUNDLE/displaycal/displaycal-storage/DisplayCAL/." "$HOME/.local/share/DisplayCAL/" 2>/dev/null || true
        fi
        # ArgyllCMS color.jcnf device mapping
        [[ -f "$BUNDLE/displaycal/color.jcnf" ]] && cp "$BUNDLE/displaycal/color.jcnf" "$HOME/.config/" 2>/dev/null || true
        # Autostart loader
        if [[ -d "$BUNDLE/displaycal/autostart" ]] && [[ -n "$(ls "$BUNDLE/displaycal/autostart/" 2>/dev/null)" ]]; then
            mkdir -p "$HOME/.config/autostart"
            cp -n "$BUNDLE/displaycal/autostart/"*.desktop "$HOME/.config/autostart/" 2>/dev/null || true
        fi
        # System ICC profiles
        if [[ -d "$BUNDLE/displaycal/icc-system" ]]; then
            sudo cp -rn "$BUNDLE/displaycal/icc-system/." /usr/share/color/icc/ 2>/dev/null || true
        fi
        ok "DisplayCAL profiles + config restored"
        log_import "RESTORED: DisplayCAL"

        if [[ "$USE_TUI" == true ]]; then
            whiptail --title "DisplayCAL — Important Note"               --msgbox "DisplayCAL ICC profiles and config restored.

SAME MONITOR as before?
  ✅ Profile should load automatically on next login.
     colord recognises the display by its EDID fingerprint.

DIFFERENT MONITOR?
  ⚠️  The profile assignment is EDID-specific.
     You need to re-run calibration with DisplayCAL
     for the new monitor, or manually assign:

     colormgr get-devices        (find your display ID)
     colormgr get-profiles       (find your profile ID)
     colormgr device-add-profile <device_id> <profile_id>
     colormgr device-make-profile-default <device_id> <profile_id>

Profile loading on login:
  The autostart entry has been restored to ~/.config/autostart/
  displaycal-apply-profiles will run on next login."               $BOX_H $BOX_W
        else
            warn "DisplayCAL: same monitor = auto. Different monitor = re-run calibration or use colormgr."
        fi
    else
        info "[DRY RUN] would restore DisplayCAL profiles and config"
    fi
fi

# ── NFS ───────────────────────────────────────────────────────────────────────
NFS_MSG=""
if [[ "$NFS_MNT" == "true" ]] || [[ "$NFS_EXP" == "true" ]]; then
    [[ "$NFS_EXP" == "true" ]] && NFS_MSG+="Server exports — still manual:\n  sudo cp $BUNDLE/nfs/exports /etc/exports\n  sudo exportfs -ra\n\n"
    if [[ "$NFS_MNT" == "true" ]] && [[ -n "$NFS_FSTAB_FILE" ]]; then
        if [[ "$DRY_RUN" == false ]]; then
            INSERTED=(); SKIPPED=()
            while IFS= read -r line; do
                [[ -z "$line" || "$line" == \#* ]] && continue
                if grep -qF "$line" /etc/fstab 2>/dev/null; then
                    SKIPPED+=("$line")
                else
                    echo "$line" | sudo tee -a /etc/fstab > /dev/null
                    INSERTED+=("$line")
                fi
            done < <(grep -E '\bnfs\b|\bnfs4\b' "$NFS_FSTAB_FILE" 2>/dev/null)
            if [[ ${#INSERTED[@]} -gt 0 ]]; then
                NFS_MSG+="Added to /etc/fstab:\n"
                for l in "${INSERTED[@]}"; do NFS_MSG+="  $l\n"; done
                NFS_MSG+="\n"
                sudo systemctl daemon-reload 2>/dev/null \
                    && NFS_MSG+="✓ systemctl daemon-reload\n" \
                    || NFS_MSG+="⚠ daemon-reload failed\n"
                sudo mount -a 2>/dev/null \
                    && NFS_MSG+="✓ mount -a\n" \
                    || NFS_MSG+="⚠ mount -a failed — check NFS server is reachable\n"
            fi
            [[ ${#SKIPPED[@]} -gt 0 ]] && { NFS_MSG+="Already present (skipped):\n"; for l in "${SKIPPED[@]}"; do NFS_MSG+="  $l\n"; done; }
        else
            NFS_MSG+="[DRY RUN] Would add to /etc/fstab:\n"
            while IFS= read -r line; do
                [[ -z "$line" || "$line" == \#* ]] && continue
                NFS_MSG+="  $line\n"
            done < <(grep -E '\bnfs\b|\bnfs4\b' "$NFS_FSTAB_FILE" 2>/dev/null)
        fi
    fi
    [[ -n "$NFS_MSG" ]] && whiptail --title "NFS" --msgbox "$NFS_MSG" $BOX_H $BOX_W
fi

# ── Final summary ─────────────────────────────────────────────────────────────
whiptail --title "✅ Import Complete!" \
  --msgbox "\
Everything selected has been restored.

Remaining manual steps:
  • Copy SSH private keys: ~/.ssh/id_*
    then run: chmod 600 ~/.ssh/id_*
  • tailscale up  (re-authenticate)
  • Re-pair Syncthing devices
  • Verify GPU drivers are loaded
  • Enable GNOME extensions via the Extensions app
    (Settings → Extensions — they are installed but off by default)
  • Reboot  ← do this last; required for services to start correctly

Import log saved to:
  $IMPORT_LOG

Check the log for any errors or skipped items." \
  $BOX_H $BOX_W

# ═════════════════════════════════════════════════════════════════════════════
# FALLBACK: non-TUI (--dry-run or whiptail not available)
# ═════════════════════════════════════════════════════════════════════════════
else

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Bundle information${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
[[ -f "$MANIFEST" ]] && grep "^# " "$MANIFEST" | sed 's/^# /  /' || echo "  (no manifest)"
echo ""
printf "  %-30s %s\n" "Native packages:"   "$NATIVE_COUNT"
printf "  %-30s %s\n" "Foreign packages:"  "$AUR_COUNT  (${SRC_PKG_MANAGER} → ${PKG_MANAGER})"
printf "  %-30s %s\n" "Flatpak apps:"      "$FLATPAK_COUNT"
printf "  %-30s %s\n" "AppImages:"         "$APPIMAGE_COUNT (manual)"
[[ "$DRY_RUN" == true ]] && echo -e "\n  ${YELLOW}DRY RUN — nothing will be written${RESET}"
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
read -rp "  Proceed with import? [Y/n] " CONFIRM
[[ "${CONFIRM,,}" == "n" ]] && { echo "  Aborted."; exit 0; }

AUR_HELPER=""
command -v yay  &>/dev/null && AUR_HELPER="yay"  || true
command -v paru &>/dev/null && AUR_HELPER="paru" || true

# ── Packages ──────────────────────────────────────────────────────────────────
if [[ "$IMP_NO_PACKAGES" == false ]]; then
    header "PHASE 2: Installing packages..."

    if [[ -n "$PKG_INSTALL_FILE" ]]; then
        [[ "$PKG_INSTALL_OLD_FORMAT" == true ]] && warn "Legacy bundle — using full package list; some names may not match this distro"
        step "Packages ($NATIVE_COUNT) via ${PKG_MANAGER}..."
        if [[ "$DRY_RUN" == false ]]; then
            case "$PKG_FAMILY" in
                arch)
                    _PACMAN_FAILED=$(mktemp)
                    sudo pacman -S --needed - < "$PKG_INSTALL_FILE" 2>&1 \
                        | tee -a "$IMPORT_LOG" \
                        | grep "^error: target not found:" \
                        | sed 's/error: target not found: //' > "$_PACMAN_FAILED" || true
                    if [[ -s "$_PACMAN_FAILED" ]] && [[ -n "$AUR_HELPER" ]]; then
                        warn "$(wc -l < "$_PACMAN_FAILED") packages not in official repos — trying $AUR_HELPER..."
                        $AUR_HELPER -S --needed - < "$_PACMAN_FAILED" 2>&1 | tee -a "$IMPORT_LOG" || warn "Some AUR packages failed"
                    elif [[ -s "$_PACMAN_FAILED" ]]; then
                        warn "$(wc -l < "$_PACMAN_FAILED") packages not found — install an AUR helper (yay/paru) and retry"
                        cat "$_PACMAN_FAILED"
                    fi
                    rm -f "$_PACMAN_FAILED"
                    ;;
                fedora) xargs sudo dnf install -y < "$PKG_INSTALL_FILE" 2>&1 | tee -a "$IMPORT_LOG" || warn "Some packages failed" ;;
                debian) xargs sudo apt install -y < "$PKG_INSTALL_FILE" 2>&1 | tee -a "$IMPORT_LOG" || warn "Some packages failed" ;;
                suse)   xargs sudo zypper install -y < "$PKG_INSTALL_FILE" 2>&1 | tee -a "$IMPORT_LOG" || warn "Some packages failed" ;;
                *)      warn "Unknown package manager — install manually from $PKG_INSTALL_FILE" ;;
            esac
        else
            info "[DRY RUN] would install $NATIVE_COUNT packages via ${PKG_MANAGER}"
        fi
    fi


    # Ubuntu/Debian fallback: re-add PPAs
    if [[ "$PKG_FAMILY" == "debian" ]] && [[ -f "$BUNDLE/packages/ppa-sources.txt" ]] && [[ -s "$BUNDLE/packages/ppa-sources.txt" ]]; then
        step "PPAs / external repos..."
        if [[ "$DRY_RUN" == false ]]; then
            if command -v add-apt-repository &>/dev/null; then
                while read -r ppa; do
                    [[ -z "$ppa" ]] && continue
                    info "Adding: $ppa"
                    sudo add-apt-repository -y "$ppa" 2>&1 | tee -a "$IMPORT_LOG" || warn "Failed: $ppa"
                done < "$BUNDLE/packages/ppa-sources.txt"
                sudo apt update 2>&1 | tee -a "$IMPORT_LOG" || true
                ok "PPAs added"
            else
                warn "add-apt-repository not found — install software-properties-common"
                cat "$BUNDLE/packages/ppa-sources.txt"
            fi
        else
            info "[DRY RUN] would add $(wc -l < "$BUNDLE/packages/ppa-sources.txt") PPAs"
        fi
    fi

    if [[ -f "$BUNDLE/packages/flatpak-apps.txt" ]] && [[ "$FLATPAK_COUNT" -gt 0 ]]; then
        step "Flatpak apps ($FLATPAK_COUNT)..."
        if command -v flatpak &>/dev/null; then
            [[ "$DRY_RUN" == false ]] \
                && flatpak install --noninteractive $(cat "$BUNDLE/packages/flatpak-apps.txt") 2>&1 | tee -a "$IMPORT_LOG" \
                && info "  Log out and back in for Flatpak apps to appear in your launcher" \
                || info "[DRY RUN] flatpak install $FLATPAK_COUNT apps"
        else
            warn "Flatpak not installed — skipping"
        fi
    fi

    if [[ "$APPIMAGE_COUNT" -gt 0 ]]; then
        warn "AppImages ($APPIMAGE_COUNT) require manual install:"
        cat "$BUNDLE/packages/appimages.txt"
    fi
fi

# ── Configs ───────────────────────────────────────────────────────────────────
header "PHASE 3: Restoring configs..."

[[ "$IMP_NO_CONFIGS" == false && "$HAS_CONFIGS"  == true ]] && { step "~/.config...";      do_copy "$BUNDLE/configs/config-dirs/." "$HOME/.config";      ok "done"; log_import "RESTORED: ~/.config"; }
[[ "$IMP_NO_CONFIGS" == false && "$HAS_DOTFILES" == true ]] && { step "Dotfiles...";       do_copy "$BUNDLE/configs/dotfiles/."    "$HOME";              ok "done"; log_import "RESTORED: dotfiles"; }
[[ "$IMP_NO_CONFIGS" == false && "$HAS_LOCAL"    == true ]] && { step "~/.local/share..."; do_copy "$BUNDLE/configs/local-share/." "$HOME/.local/share"; ok "done"; log_import "RESTORED: ~/.local/share"; }
[[ "$IMP_NO_FLATPAK" == false && "$HAS_FLATPAK"  == true ]] && { step "Flatpak data...";   do_copy "$BUNDLE/flatpak/var-app/."     "$HOME/.var/app";     ok "done"; log_import "RESTORED: ~/.var/app"; }

if [[ "$IMP_NO_BROWSERS" == false && "$HAS_BROWSERS" == true ]]; then
    step "Browsers..."
    grep "^browser:" "$MANIFEST" 2>/dev/null | while IFS=: read -r _ name orig_dir bundle_subdir; do
        BUNDLE_SRC="$BUNDLE/$bundle_subdir"
        [[ -d "$BUNDLE_SRC" ]] && do_copy "$BUNDLE_SRC/." "$(dirname "$orig_dir")" && ok "$name" && log_import "RESTORED: browser $name"
    done
fi

if [[ "$IMP_NO_GNOME" == false && "$HAS_GNOME" == true ]]; then
    step "GNOME..."
    [[ -d "$BUNDLE/gnome/extensions-backup" ]] && do_copy "$BUNDLE/gnome/extensions-backup/." "$HOME/.local/share/gnome-shell/extensions"
    [[ -f "$BUNDLE/gnome/dconf-full.ini" ]] && command -v dconf &>/dev/null && [[ "$DRY_RUN" == false ]] && dconf load / < "$BUNDLE/gnome/dconf-full.ini" && ok "dconf loaded" && log_import "RESTORED: dconf"
fi

if [[ "$IMP_NO_SSH" == false && "$HAS_SSH" == true ]]; then
    step "SSH..."
    [[ "$DRY_RUN" == false ]] && { mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; }
    [[ -f "$BUNDLE/ssh/config" ]]          && do_copy "$BUNDLE/ssh/config"          "$HOME/.ssh" --file
    [[ -f "$BUNDLE/ssh/known_hosts" ]]     && do_copy "$BUNDLE/ssh/known_hosts"     "$HOME/.ssh" --file
    [[ -f "$BUNDLE/ssh/authorized_keys" ]] && do_copy "$BUNDLE/ssh/authorized_keys" "$HOME/.ssh" --file
    ok "SSH restored"; log_import "RESTORED: SSH"
fi

if [[ "$IMP_NO_FONTS" == false && "$HAS_FONTS" == true ]]; then
    step "Fonts..."
    [[ "$DRY_RUN" == false ]] && {
        mkdir -p "$HOME/.local/share/fonts"
        for d in "$BUNDLE/fonts"/*/; do cp -rn "$d/." "$HOME/.local/share/fonts/" 2>/dev/null || true; done
        fc-cache -fv > /dev/null 2>&1
    } || info "[DRY RUN] would restore fonts"
    ok "Fonts restored"; log_import "RESTORED: fonts"
fi

if [[ "$IMP_NO_STEAM" == false && "$HAS_STEAM" == true ]]; then
    step "Steam..."
    STEAM_DEST="$HOME/.local/share/Steam"
    [[ "$DRY_RUN" == false ]] && mkdir -p "$STEAM_DEST"
    for d in "$BUNDLE/steam"/*/; do
        NAME=$(basename "$d"); [[ "$NAME" == "dot-steam" ]] && continue
        do_copy "$d" "$STEAM_DEST/$NAME" && ok "Steam: $NAME"
    done
    [[ "$DRY_RUN" == false ]] && find "$BUNDLE/steam" -maxdepth 1 -name "*.vdf" -exec cp -n {} "$STEAM_DEST/" \; 2>/dev/null || true
    log_import "RESTORED: Steam"
fi

if [[ "$IMP_NO_HOMEDIRS" == false && "$HAS_HOMEDIRS" == true ]]; then
    step "XDG home directories..."
    grep "^homedir:" "$MANIFEST" 2>/dev/null | while IFS=: read -r _ xdg orig_dir bundle_subdir; do
        BUNDLE_SRC="$BUNDLE/$bundle_subdir"
        DEST_PARENT=$(dirname "$orig_dir")
        [[ -d "$BUNDLE_SRC" ]] && do_copy "$BUNDLE_SRC" "$DEST_PARENT" && ok "homedirs: $xdg" && log_import "RESTORED: homedir $xdg"
    done
fi

if [[ "$IMP_NO_USERHOMES" == false && "$HAS_USERHOMES" == true ]]; then
    step "/home user directories..."
    grep "^userhome:" "$MANIFEST" 2>/dev/null | while IFS=: read -r _ name orig_dir bundle_subdir; do
        BUNDLE_SRC="$BUNDLE/$bundle_subdir"
        if [[ -d "$BUNDLE_SRC" ]]; then
            [[ "$DRY_RUN" == true ]] && { info "[DRY RUN] would sudo cp -rn $BUNDLE_SRC/. $orig_dir"; continue; }
            sudo mkdir -p "$orig_dir"
            sudo cp -rn "$BUNDLE_SRC/." "$orig_dir/" 2>/dev/null || warn "Some files may not have copied for $name"
            ok "/home/$name restored"; log_import "RESTORED: /home/$name"
        fi
    done
fi

if [[ "$IMP_NO_CUPS" == false ]] && [[ -d "$BUNDLE/cups" ]] && [[ -n "$(ls "$BUNDLE/cups/" 2>/dev/null)" ]]; then
    CUPS_Q=$(grep -c "^<Printer " "$BUNDLE/cups/printers.conf" 2>/dev/null || echo 0)
    step "CUPS printers ($CUPS_Q queues)..."
    if [[ "$DRY_RUN" == false ]]; then
        [[ -f "$BUNDLE/cups/printers.conf" ]] && sudo cp "$BUNDLE/cups/printers.conf" /etc/cups/ 2>/dev/null || warn "printers.conf needs manual copy"
        [[ -f "$BUNDLE/cups/cupsd.conf"    ]] && sudo cp "$BUNDLE/cups/cupsd.conf"    /etc/cups/ 2>/dev/null || true
        [[ -f "$BUNDLE/cups/lpoptions"     ]] && sudo cp "$BUNDLE/cups/lpoptions"     /etc/cups/ 2>/dev/null || true
        [[ -d "$BUNDLE/cups/ppd"           ]] && sudo cp "$BUNDLE/cups/ppd/"*.ppd /etc/cups/ppd/ 2>/dev/null || true
        [[ -f "$BUNDLE/cups/user-cups/lpoptions" ]] && { mkdir -p "$HOME/.cups"; cp "$BUNDLE/cups/user-cups/lpoptions" "$HOME/.cups/" 2>/dev/null || true; }
        sudo systemctl restart cups 2>/dev/null || true
        ok "CUPS config restored — verify queues at http://localhost:631"
        log_import "RESTORED: CUPS"
    else
        info "[DRY RUN] would restore CUPS config ($CUPS_Q queues)"
    fi
    warn "CUPS: verify printers at http://localhost:631 or lpstat -v"
fi

if [[ "$IMP_NO_DISPLAYCAL" == false ]] && [[ -d "$BUNDLE/displaycal" ]] && [[ -n "$(ls "$BUNDLE/displaycal/" 2>/dev/null)" ]]; then
    step "DisplayCAL / ArgyllCMS profiles..."
    if [[ "$DRY_RUN" == false ]]; then
        [[ -d "$BUNDLE/displaycal/icc-user" ]] && { mkdir -p "$HOME/.local/share/color"; cp -rn "$BUNDLE/displaycal/icc-user/." "$HOME/.local/share/color/" 2>/dev/null || true; }
        [[ -d "$BUNDLE/displaycal/icc-home" ]] && { mkdir -p "$HOME/.color"; cp -rn "$BUNDLE/displaycal/icc-home/." "$HOME/.color/" 2>/dev/null || true; }
        [[ -d "$BUNDLE/displaycal/displaycal-storage/DisplayCAL" ]] && { mkdir -p "$HOME/.local/share/DisplayCAL"; cp -rn "$BUNDLE/displaycal/displaycal-storage/DisplayCAL/." "$HOME/.local/share/DisplayCAL/" 2>/dev/null || true; }
        [[ -f "$BUNDLE/displaycal/color.jcnf" ]] && cp "$BUNDLE/displaycal/color.jcnf" "$HOME/.config/" 2>/dev/null || true
        [[ -d "$BUNDLE/displaycal/autostart" ]] && { mkdir -p "$HOME/.config/autostart"; cp -n "$BUNDLE/displaycal/autostart/"*.desktop "$HOME/.config/autostart/" 2>/dev/null || true; }
        [[ -d "$BUNDLE/displaycal/icc-system" ]] && sudo cp -rn "$BUNDLE/displaycal/icc-system/." /usr/share/color/icc/ 2>/dev/null || true
        ok "DisplayCAL profiles + config restored"
        log_import "RESTORED: DisplayCAL"
    else
        info "[DRY RUN] would restore DisplayCAL profiles and config"
    fi
    warn "DisplayCAL: same monitor = profile loads automatically. Different monitor = re-run calibration or use colormgr."
fi

if [[ "$NFS_MNT" == "true" ]] && [[ -n "$NFS_FSTAB_FILE" ]]; then
    if [[ "$DRY_RUN" == false ]]; then
        info "NFS fstab mounts — inserting into /etc/fstab..."
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            if grep -qF "$line" /etc/fstab 2>/dev/null; then
                ok "  Already present: $line"
            else
                echo "$line" | sudo tee -a /etc/fstab > /dev/null
                ok "  Added: $line"
            fi
        done < <(grep -E '\bnfs\b|\bnfs4\b' "$NFS_FSTAB_FILE" 2>/dev/null)
        sudo systemctl daemon-reload 2>/dev/null && ok "systemctl daemon-reload" || warn "daemon-reload failed"
        sudo mount -a 2>/dev/null && ok "NFS shares mounted" || warn "mount -a failed — check NFS server is reachable"
    else
        info "[DRY RUN] would add to /etc/fstab:"
        grep -E '\bnfs\b|\bnfs4\b' "$NFS_FSTAB_FILE" 2>/dev/null | while IFS= read -r line; do info "  $line"; done
    fi
fi

fi # end TUI/fallback

# ── Final output (both modes) ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
[[ "$DRY_RUN" == true ]] \
    && echo -e "${YELLOW}${BOLD}  Dry run complete — nothing written.${RESET}" \
    || echo -e "${GREEN}${BOLD}  Import complete!${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
[[ "$DRY_RUN" == false ]] && echo "  Import log: $IMPORT_LOG"
echo ""
echo -e "  ${YELLOW}Manual steps remaining:${RESET}"
echo "    • Copy SSH private keys and chmod 600 ~/.ssh/id_*"
echo "    • Verify NFS shares mounted  (fstab lines inserted; mount -a already run)"
echo "    • tailscale up"
echo "    • Re-pair Syncthing devices"
echo "    • Enable GNOME extensions via Extensions app"
echo "      (Settings → Extensions — they are installed but off by default)"
echo "    • Verify GPU drivers"
echo "    • Reboot  ← required for services to start correctly"
echo ""

fi # [[ "$MODE" == "import" ]]
