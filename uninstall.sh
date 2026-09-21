#!/bin/sh
# IGM — Income Generator Uninstaller
# Usage:  curl -fsSL https://raw.githubusercontent.com/nxyystore/income-generator/installer/uninstall.sh | sh
#     or: curl -fsSL .../uninstall.sh | sh -s -- --yes
# Options:
#   -y, --yes        non-interactive, skip confirmation
#   --keep-repo      do not delete ~/.igm
#   --keep-binary    do not delete binary (only clean shell integration)

set -e

BIN_NAME="igm"
IGM_HOME="${HOME}/.igm"

if [ -t 1 ]; then
    RED='\033[0;31m' GREEN='\033[0;32m' CYAN='\033[0;36m' YELLOW='\033[0;33m' BOLD='\033[1m' NC='\033[0m'
else
    RED='' GREEN='' CYAN='' YELLOW='' BOLD='' NC=''
fi

info() { printf "${CYAN}==>${NC} ${BOLD}%s${NC}\n" "$*"; }
ok()   { printf "${GREEN}  ✓${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}  !${NC} %s\n" "$*"; }
fail() { printf "${RED}  ✗ Error:${NC} %s\n" "$*" >&2; exit 1; }

SKIP_CONFIRM=0
KEEP_REPO=0
KEEP_BINARY=0

for arg in "$@"; do
    case "$arg" in
        -y|--yes)       SKIP_CONFIRM=1 ;;
        --keep-repo)    KEEP_REPO=1 ;;
        --keep-binary)  KEEP_BINARY=1 ;;
        -h|--help)
            printf "Usage: uninstall.sh [OPTIONS]\n\n"
            printf "Options:\n"
            printf "  -y, --yes        skip confirmation prompt\n"
            printf "  --keep-repo      keep %s\n" "$IGM_HOME"
            printf "  --keep-binary    keep binary, only clean shell config\n"
            printf "  -h, --help       show this help\n"
            exit 0
            ;;
        *) warn "Unknown option: $arg (ignored)" ;;
    esac
done

# Resolve all possible binary locations
resolve_binary_paths() {
    PATHS=""
    if [ -n "$INSTALL_DIR" ]; then
        PATHS="$INSTALL_DIR/$BIN_NAME"
    fi
    # Common locations set by the installer
    for dir in "${HOME}/.local/bin" "/usr/local/bin"; do
        case "$PATHS" in
            *"$dir/$BIN_NAME"*) ;;
            *) PATHS="$PATHS $dir/$BIN_NAME" ;;
        esac
    done
    # Also check wherever `igm` resolves on PATH
    if command -v "$BIN_NAME" >/dev/null 2>&1; then
        _found="$(command -v "$BIN_NAME" 2>/dev/null || true)"
        case "$PATHS" in
            *"$_found"*) ;;
            *) PATHS="$PATHS $_found" ;;
        esac
    fi
}

remove_binary() {
    if [ "$KEEP_BINARY" = "1" ]; then
        warn "Skipping binary removal (--keep-binary)"
        return
    fi
    found=0
    for bin in $PATHS; do
        [ -f "$bin" ] || [ -h "$bin" ] || continue
        found=1
        info "Removing $bin ..."
        if [ -w "$(dirname "$bin")" ]; then
            rm -f "$bin" && ok "Removed $bin" || warn "Failed to remove $bin"
        else
            if command -v sudo >/dev/null 2>&1; then
                sudo rm -f "$bin" && ok "Removed $bin (sudo)" || warn "Failed to remove $bin"
            else
                warn "No write permission for $bin and sudo not available — please remove manually"
            fi
        fi
    done
    if [ "$found" = "0" ]; then
        warn "No installed binary found (checked: $PATHS)"
    fi
}

remove_repo() {
    if [ "$KEEP_REPO" = "1" ]; then
        warn "Skipping repo removal (--keep-repo) — keeping $IGM_HOME"
        return
    fi
    if [ -d "$IGM_HOME" ]; then
        info "Removing $IGM_HOME ..."
        rm -rf "$IGM_HOME" && ok "Removed $IGM_HOME" || warn "Failed to remove $IGM_HOME"
    elif [ -e "$IGM_HOME" ]; then
        warn "$IGM_HOME exists but is not a directory — removing"
        rm -rf "$IGM_HOME" && ok "Removed $IGM_HOME"
    else
        warn "No repo found at $IGM_HOME"
    fi
}

clean_shell_profiles() {
    info "Cleaning shell PATH entries..."

    cleaned=0

    # Patterns the installer adds
    #   export PATH="$HOME/.local/bin:$PATH"   (in .bashrc / .zshrc)
    #   fish_add_path "$HOME/.local/bin"        (in config.fish)
    for profile in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile" "${HOME}/.bash_aliases"; do
        [ -f "$profile" ] || continue
        # Only touch files that contain the installer line
        if grep -qF '.local/bin' "$profile" 2>/dev/null; then
            _tmp="${profile}.igm.$$"
            # Remove exactly the lines the installer added; leave user-added PATH lines intact
            # Matches: export PATH="$HOME/.local/bin:$PATH"  with various quoting
            sed \
                -e '/export PATH=.*\.local\/bin.*\$PATH/d' \
                -e '/fish_add_path.*\.local\/bin/d' \
                "$profile" > "$_tmp" && mv "$_tmp" "$profile" && cleaned=1 && ok "Cleaned $profile"
        fi
        # Dedup leftover duplicates (same logic as installer)
        for _dir in "${HOME}/.local/bin" "/usr/local/bin"; do
            [ -f "$profile" ] || continue
            _count=$(grep -cF "$_dir" "$profile" 2>/dev/null || true)
            if [ "$_count" -gt 1 ]; then
                _tmp="${profile}.igm.$$"
                awk -v dir="$_dir" 'index($0,dir){if(!seen++)print;next}1' "$profile" > "$_tmp" && mv "$_tmp" "$profile"
            fi
        done
    done

    _fish="${HOME}/.config/fish/config.fish"
    if [ -f "$_fish" ] && grep -qF '.local/bin' "$_fish" 2>/dev/null; then
        _tmp="${_fish}.igm.$$"
        sed -e '/fish_add_path.*\.local\/bin/d' -e '/\.local\/bin.*fish_add_path/d' "$_fish" > "$_tmp" && mv "$_tmp" "$_fish" && cleaned=1 && ok "Cleaned $_fish"
    fi

    # Legacy alias (installer strips it on install — also strip on uninstall)
    for profile in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile" "${HOME}/.bash_aliases" "${HOME}/.config/fish/config.fish"; do
        [ -f "$profile" ] || continue
        if grep -q "alias igm=.*start\\.sh" "$profile" 2>/dev/null; then
            _tmp="${profile}.igm.$$"
            sed '/alias igm=.*start\.sh/d' "$profile" > "$_tmp" && mv "$_tmp" "$profile" && ok "Removed legacy alias from $profile"
        fi
    done

    if [ "$cleaned" = "0" ]; then
        warn "No shell PATH entries to clean"
    fi
}

main() {
    printf "\n${BOLD}IGM — Income Generator Uninstaller${NC}\n\n"

    resolve_binary_paths

    printf "This will remove:\n"
    if [ "$KEEP_BINARY" = "0" ]; then
        printf "  • Binary:  %s\n" "$PATHS"
    else
        printf "  • Binary:  (skipped)\n"
    fi
    if [ "$KEEP_REPO" = "0" ]; then
        printf "  • Repo:    %s\n" "$IGM_HOME"
    else
        printf "  • Repo:    (skipped)\n"
    fi
    printf "  • Shell PATH lines added by the installer\n"
    printf "  • Legacy alias (if present)\n"
    printf "\n"
    warn "Windows users: also run uninstall.cmd to remove %%APPDATA%%\\IGM and PATH entry"
    printf "\n"

    if [ "$SKIP_CONFIRM" = "0" ]; then
        printf "Continue? [y/N] "
        read -r ans
        case "$ans" in
            y|Y|yes|YES) ;;
            *) printf "Aborted.\n"; exit 0 ;;
        esac
        printf "\n"
    fi

    remove_binary
    remove_repo
    clean_shell_profiles

    # Final check
    if command -v "$BIN_NAME" >/dev/null 2>&1; then
        warn "igm is still on PATH: $(command -v "$BIN_NAME")"
        warn "Open a new terminal or run: hash -r; unalias igm 2>/dev/null; true"
    else
        ok "igm is no longer on PATH"
    fi

    printf "\n${GREEN}${BOLD}Uninstall complete.${NC}\n\n"
    printf "Restart your terminal (or run ${BOLD}source ~/.bashrc${NC} / ${BOLD}source ~/.zshrc${NC}) to refresh PATH.\n"
    printf "To reinstall, run the installer again.\n\n"
}

main "$@"
