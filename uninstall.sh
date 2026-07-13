#!/bin/bash
#
# JuhRadial MX Uninstaller
# https://github.com/JuhLabs/juhradial-mx
#
# Reverses install.sh: stops the user services and removes the installed
# binaries, assets, desktop entries, udev rules, autostart entry and (on GNOME)
# the cursor-helper extension. Your configuration under ~/.config/juhradial is
# KEPT unless you pass --purge. Shared dependencies (python, rust, ydotool, ...)
# and your 'input' group membership are left untouched.
#
# Usage:  ./uninstall.sh [--purge] [--yes]
#           --purge   also delete ~/.config/juhradial (themes, button maps, macros)
#           --yes     skip the confirmation prompt
#

set -e

# ── Colors & Formatting ──────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'

# ── Configuration (mirrors install.sh) ───────────────────────────────
INSTALL_DIR="/opt/juhradial-mx"
BIN_DIR="/usr/local/bin"
SHARE_DIR="/usr/share/juhradial"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/juhradial"
GNOME_EXT_UUID="juhradial-cursor@dev.juhlabs.com"
GNOME_EXT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$GNOME_EXT_UUID"

PURGE_CONFIG=false
ASSUME_YES=false
DESKTOP_TYPE="other"

TOTAL_STEPS=5
CURRENT_STEP=0

# ── Output helpers ───────────────────────────────────────────────────
step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo ""
    echo -e "  ${CYAN}${BOLD}[$CURRENT_STEP/$TOTAL_STEPS]${RESET} ${BOLD}$1${RESET}"
    echo -e "  ${GRAY}$(printf '%.0s─' {1..48})${RESET}"
}
log_info()    { echo -e "  ${BLUE}→${RESET} $1"; }
log_success() { echo -e "  ${GREEN}✓${RESET} $1"; }
log_warning() { echo -e "  ${YELLOW}!${RESET} ${YELLOW}$1${RESET}"; }
log_error()   { echo -e "  ${RED}✗${RESET} ${RED}$1${RESET}"; }
log_dim()     { echo -e "  ${GRAY}  $1${RESET}"; }

# ── Pre-flight ───────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run this script as root. It will ask for sudo when needed."
        exit 1
    fi
}

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --purge)   PURGE_CONFIG=true ;;
            --yes|-y)  ASSUME_YES=true ;;
            -h|--help)
                echo "Usage: $0 [--purge] [--yes]"
                echo "  --purge   also delete $CONFIG_DIR (themes, button maps, macros)"
                echo "  --yes     skip the confirmation prompt"
                exit 0 ;;
            *) log_warning "Ignoring unknown option: $arg" ;;
        esac
    done
}

detect_desktop() {
    if [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
        DESKTOP_TYPE="hyprland"
    elif [[ "$XDG_CURRENT_DESKTOP" == *"GNOME"* ]]; then
        DESKTOP_TYPE="gnome"
    fi
}

print_banner() {
    local BCYAN='\033[1;96m'
    echo ""
    echo -e "${BCYAN}"
    cat << 'BANNER'
    ___       _    ______          _ _       _  ___  ____  __
   |_  |     | |   | ___ \        | (_)     | | |  \/  \ \ / /
     | |_   _| |__ | |_/ /__ _  __| |_  __ _| | | .  . |\ V /
     | | | | | '_ \|    // _` |/ _` | |/ _` | | | |\/| |/   \
 /\__/ | |_| | | | | |\ | (_| | (_| | | (_| | | | |  | / /^\ \
 \____/ \__,_|_| |_\_| \_\__,_|\__,_|_|\__,_|_| \_|  |_\/   \/
BANNER
    echo -e "${RESET}"
    echo -e "                      ${CYAN}· Uninstaller${RESET}"
    echo ""
}

confirm() {
    [ "$ASSUME_YES" = true ] && return 0
    echo -e "  ${BOLD}Remove JuhRadial MX?${RESET} ${DIM}[y/N]${RESET} \c"
    read -n 1 -r < /dev/tty
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        log_info "Cancelled. Nothing was changed."
        exit 0
    fi
}

# ── Step 1: services & autostart ─────────────────────────────────────
stop_services() {
    step "Stopping services and autostart"

    if command -v systemctl &> /dev/null; then
        if systemctl --user disable --now juhradialmx-daemon.service 2>/dev/null; then
            log_success "Daemon stopped and disabled"
        else
            log_dim "Daemon service was not active"
        fi

        # Only remove OUR ydotoold unit; a distro-provided one is left alone.
        local yd="$SYSTEMD_USER_DIR/ydotoold.service"
        if [ -f "$yd" ] && grep -q "JuhRadial" "$yd" 2>/dev/null; then
            systemctl --user disable --now ydotoold.service 2>/dev/null || true
            rm -f "$yd"
            log_success "ydotoold unit removed"
        fi

        rm -f "$SYSTEMD_USER_DIR/juhradialmx-daemon.service"
        systemctl --user daemon-reload 2>/dev/null || true
    else
        log_dim "systemctl not available — skipping services"
    fi

    # The overlay/tray app is not a service; stop a running instance.
    if pkill -f "[j]uhradial-overlay.py" 2>/dev/null; then
        log_success "Overlay/tray app stopped"
    fi

    if rm -f "$AUTOSTART_DIR/juhradial-mx.desktop" 2>/dev/null; then
        log_success "Autostart entry removed"
    fi
}

# ── Step 2: installed system files ───────────────────────────────────
remove_system_files() {
    step "Removing installed files"
    log_info "These live under /usr and /opt; sudo will prompt for your password."

    sudo rm -f "$BIN_DIR/juhradiald" \
               "$BIN_DIR/juhradial-mx" \
               "$BIN_DIR/juhradial-settings"
    sudo rm -rf "$SHARE_DIR" "$INSTALL_DIR"
    sudo rm -f /usr/share/applications/juhradial-mx.desktop \
               /usr/share/applications/org.kde.juhradialmx.settings.desktop \
               /usr/share/icons/hicolor/scalable/apps/juhradial-mx.svg
    log_success "Binaries, overlay, assets and desktop entries removed"
}

# ── Step 3: udev rules & uinput module config ────────────────────────
remove_udev_rules() {
    step "Removing udev rules"
    sudo rm -f /etc/udev/rules.d/99-juhradialmx.rules \
               /etc/udev/rules.d/60-ydotool-uinput.rules \
               /etc/modules-load.d/juhradial-uinput.conf
    if command -v udevadm &> /dev/null; then
        sudo udevadm control --reload-rules 2>/dev/null || true
        sudo udevadm trigger 2>/dev/null || true
    fi
    log_success "udev rules and uinput module config removed"
}

# ── Step 4: desktop-specific integration ─────────────────────────────
remove_hyprland_rules() {
    local hypr_dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
    [ -d "$hypr_dir" ] || return 0

    local removed=false
    [ -f "$hypr_dir/juhradial-rules.conf" ] && { rm -f "$hypr_dir/juhradial-rules.conf"; removed=true; }

    # Strip the source line and the inline rule block from any *.conf. Back up
    # each edited file first so a hand-tuned config is never lost.
    local f
    while IFS= read -r -d '' f; do
        if grep -qE "juhradial-rules\.conf|JuhRadial MX" "$f" 2>/dev/null; then
            cp "$f" "$f.juhradial.bak"
            sed -i -e '/source=juhradial-rules.conf/d' \
                   -e '/JuhRadial MX/d' \
                   -e '/# These rules ensure the radial menu appears correctly as an overlay/d' \
                   "$f"
            removed=true
        fi
    done < <(find "$hypr_dir" -maxdepth 2 -name '*.conf' -print0 2>/dev/null)

    if [ "$removed" = true ]; then
        log_success "Hyprland window rules removed (backups: *.juhradial.bak)"
        command -v hyprctl &> /dev/null && hyprctl reload 2>/dev/null || true
    fi
}

remove_desktop_integration() {
    step "Desktop integration cleanup"

    # GNOME cursor-helper extension
    if command -v gnome-extensions &> /dev/null; then
        gnome-extensions disable "$GNOME_EXT_UUID" 2>/dev/null || true
    fi
    if [ -d "$GNOME_EXT_DIR" ]; then
        rm -rf "$GNOME_EXT_DIR"
        log_success "GNOME cursor extension removed"
    fi

    remove_hyprland_rules

    if [ "$DESKTOP_TYPE" != "gnome" ] && [ ! -d "${XDG_CONFIG_HOME:-$HOME/.config}/hypr" ]; then
        log_dim "No desktop-specific integration to remove"
    fi
}

# ── Step 5: configuration ────────────────────────────────────────────
remove_config() {
    step "Configuration"
    if [ "$PURGE_CONFIG" = true ]; then
        rm -rf "$CONFIG_DIR"
        log_success "Removed $CONFIG_DIR"
    elif [ -d "$CONFIG_DIR" ]; then
        log_info "Kept your configuration: ${WHITE}$CONFIG_DIR${RESET}"
        log_dim "Re-run with --purge to delete it (themes, button maps, macros)."
    else
        log_dim "No configuration directory to remove."
    fi
}

# ── Completion ───────────────────────────────────────────────────────
print_done() {
    echo ""
    echo -e "  ${GREEN}${BOLD}╭──────────────────────────────────────────╮${RESET}"
    echo -e "  ${GREEN}${BOLD}│                                          │${RESET}"
    echo -e "  ${GREEN}${BOLD}│   ✓  JuhRadial MX uninstalled            │${RESET}"
    echo -e "  ${GREEN}${BOLD}│                                          │${RESET}"
    echo -e "  ${GREEN}${BOLD}╰──────────────────────────────────────────╯${RESET}"
    echo ""
    echo -e "  ${BOLD}Left in place${RESET}"
    echo -e "  ${GRAY}$(printf '%.0s─' {1..48})${RESET}"
    echo -e "  ${DIM}•${RESET} Shared packages (python, rust, ydotool, …) — remove via your package manager if unused"
    echo -e "  ${DIM}•${RESET} Your ${WHITE}input${RESET} group membership — other devices may rely on it"
    if [ "$PURGE_CONFIG" = false ] && [ -d "$CONFIG_DIR" ]; then
        echo -e "  ${DIM}•${RESET} Config at ${WHITE}$CONFIG_DIR${RESET} — re-run with ${CYAN}--purge${RESET} to delete"
    fi
    echo ""
    if [ "$DESKTOP_TYPE" = "gnome" ]; then
        log_dim "GNOME: log out and back in to fully unload the cursor extension."
    fi
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    print_banner
    check_root
    detect_desktop

    echo -e "  This removes JuhRadial MX: daemon, overlay, assets, desktop"
    echo -e "  entries, udev rules and the autostart entry."
    if [ "$PURGE_CONFIG" = true ]; then
        echo -e "  ${YELLOW}Your configuration ($CONFIG_DIR) will also be deleted.${RESET}"
    else
        echo -e "  ${DIM}Your configuration is kept (pass --purge to remove it too).${RESET}"
    fi
    echo ""
    confirm

    stop_services
    remove_system_files
    remove_udev_rules
    remove_desktop_integration
    remove_config
    print_done
}

main "$@"
