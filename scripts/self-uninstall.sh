#!/bin/sh
# IGM — Self-uninstall (called via `igm self-uninstall` or `igm uninstall --self`)
# Removes containers, binary, repo and shell integration.
# Flags: -y/--yes  --keep-containers  --keep-binary  --keep-repo

set -e

BIN_NAME="igm"
IGM_HOME_DEFAULT="${HOME}/.igm"

# Allow override for testing, but default to $IGM_HOME if set else ~/.igm
IGM_HOME="${IGM_HOME:-$IGM_HOME_DEFAULT}"
ROOT_DIR_FALLBACK="$(pwd)"

if [ -t 1 ]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi

info() { printf "${CYAN}==>${NC} ${BOLD}%s${NC}\n" "$*"; }
ok()   { printf "${GREEN}  ✓${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}  !${NC} %s\n" "$*"; }
fail() { printf "${RED}  ✗ Error:${NC} %s\n" "$*" >&2; exit 1; }

SKIP_CONFIRM=0
KEEP_CONTAINERS=0
KEEP_BINARY=0
KEEP_REPO=0

for arg in "$@"; do
    case "$arg" in
        -y|--yes)            SKIP_CONFIRM=1 ;;
        --keep-containers)   KEEP_CONTAINERS=1 ;;
        --keep-binary)       KEEP_BINARY=1 ;;
        --keep-repo)         KEEP_REPO=1 ;;
        -h|--help)
            printf "Usage: igm self-uninstall [OPTIONS]\n"
            printf "       igm uninstall --self [OPTIONS]\n\n"
            printf "Options:\n"
            printf "  -y, --yes            skip confirmation\n"
            printf "  --keep-containers    do not stop/remove deployed containers\n"
            printf "  --keep-binary        keep binary at ~/.local/bin/igm\n"
            printf "  --keep-repo          keep repo at ~/.igm\n"
            printf "  -h, --help           show this help\n"
            exit 0
            ;;
        --self) ;; # consumed by caller
        *) warn "Unknown option: $arg (ignored)" ;;
    esac
done

# Detect container runtime (best-effort, no hard dependency)
CONTAINER_ALIAS=""
CONTAINER_COMPOSE=""
if command -v docker >/dev/null 2>&1; then
    CONTAINER_ALIAS="docker"
    if docker compose version >/dev/null 2>&1; then
        CONTAINER_COMPOSE="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        CONTAINER_COMPOSE="docker-compose"
    fi
elif command -v podman >/dev/null 2>&1; then
    CONTAINER_ALIAS="podman"
    if podman compose version >/dev/null 2>&1; then
        CONTAINER_COMPOSE="podman compose"
    fi
fi

remove_containers() {
    if [ "$KEEP_CONTAINERS" = "1" ]; then
        warn "Skipping container removal (--keep-containers)"
        return
    fi
    if [ -z "$CONTAINER_ALIAS" ]; then
        warn "No container runtime found — skipping container cleanup"
        return
    fi
    # Check if any IGM containers exist
    if ! $CONTAINER_ALIAS ps -a -q -f "label=project" 2>/dev/null | grep -q .; then
        warn "No IGM containers found"
        return
    fi
    info "Stopping and removing IGM containers..."

    # Prefer compose down if compose files are available, fall back to rm -f
    COMPOSE_DIR=""
    if [ -f "$IGM_HOME/compose/compose.yml" ]; then
        COMPOSE_DIR="$IGM_HOME/compose"
    elif [ -f "$ROOT_DIR_FALLBACK/compose/compose.yml" ]; then
        COMPOSE_DIR="$ROOT_DIR_FALLBACK/compose"
    elif [ -f "./compose/compose.yml" ]; then
        COMPOSE_DIR="./compose"
    fi

    if [ -n "$COMPOSE_DIR" ] && [ -n "$CONTAINER_COMPOSE" ]; then
        # Try compose down for both standard and proxy projects
        for f in "$COMPOSE_DIR"/compose.yml; do
            [ -f "$f" ] || continue
            # Down all IGM projects — ignore errors (e.g. no env file)
            $CONTAINER_COMPOSE -f "$COMPOSE_DIR/compose.yml" \
                -f "$COMPOSE_DIR/compose.unlimited.yml" \
                -f "$COMPOSE_DIR/compose.hosting.yml" \
                -f "$COMPOSE_DIR/compose.local.yml" \
                -f "$COMPOSE_DIR/compose.single.yml" \
                -f "$COMPOSE_DIR/compose.service.yml" \
                -f "$COMPOSE_DIR/compose.proxy.yml" \
                down -v 2>/dev/null || true
            break
        done
        # Also bring down proxy compose
        $CONTAINER_COMPOSE -f "$COMPOSE_DIR/compose.proxy.yml" down -v 2>/dev/null || true
    fi

    # Fallback: force-remove any remaining containers with IGM labels
    for label in "project=standard" "project=proxy"; do
        ids=$($CONTAINER_ALIAS ps -a -q -f "label=$label" 2>/dev/null || true)
        if [ -n "$ids" ]; then
            # shellcheck disable=SC2086
            $CONTAINER_ALIAS rm -f -v $ids 2>/dev/null || true
        fi
    done
    # Prune orphans with same label (containers, volumes, networks)
    $CONTAINER_ALIAS container prune -f --filter "label=project=standard" 2>/dev/null || true
    $CONTAINER_ALIAS container prune -f --filter "label=project=proxy" 2>/dev/null || true
    $CONTAINER_ALIAS volume prune -f --filter "label=project=standard" 2>/dev/null || true
    $CONTAINER_ALIAS volume prune -f --filter "label=project=proxy" 2>/dev/null || true
    $CONTAINER_ALIAS network prune -f --filter "label=project=standard" 2>/dev/null || true
    $CONTAINER_ALIAS network prune -f --filter "label=project=proxy" 2>/dev/null || true
    # Watchtower image is labelled but may remain — prune it if no containers left
    $CONTAINER_ALIAS rm -f watchtower-igm 2>/dev/null || true
    ok "Containers cleaned"
}

resolve_binary_paths() {
    PATHS=""
    if [ -n "$INSTALL_DIR" ]; then
        PATHS="$INSTALL_DIR/$BIN_NAME"
    fi
    for dir in "${HOME}/.local/bin" "/usr/local/bin"; do
        case "$PATHS" in
            *"$dir/$BIN_NAME"*) ;;
            *) PATHS="$PATHS $dir/$BIN_NAME" ;;
        esac
    done
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
    resolve_binary_paths
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
                warn "No write permission for $bin and sudo not available — remove manually"
            fi
        fi
    done
    if [ "$found" = "0" ]; then
        warn "No binary found (checked: $PATHS)"
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
        rm -rf "$IGM_HOME" && ok "Removed $IGM_HOME"
    else
        warn "No repo at $IGM_HOME"
    fi
    # Also remove alternative location if IGM was run from a different ROOT_DIR
    if [ "$ROOT_DIR_FALLBACK" != "$IGM_HOME" ] && [ -d "$ROOT_DIR_FALLBACK/.git" ]; then
        # Avoid deleting if we're inside a dev checkout that isn't ~/.igm
        case "$ROOT_DIR_FALLBACK" in
            "$HOME/.igm"*) ;;
            *) warn "Repo also at $ROOT_DIR_FALLBACK — not auto-removed (dev checkout?)" ;;
        esac
    fi
}

clean_shell_profiles() {
    info "Cleaning shell PATH entries..."
    cleaned=0
    for profile in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile" "${HOME}/.bash_aliases"; do
        [ -f "$profile" ] || continue
        if grep -qF '.local/bin' "$profile" 2>/dev/null; then
            _tmp="${profile}.igm.$$"
            sed -e '/export PATH=.*\.local\/bin.*\$PATH/d' -e '/fish_add_path.*\.local\/bin/d' "$profile" > "$_tmp" && mv "$_tmp" "$profile" && cleaned=1 && ok "Cleaned $profile"
        fi
        for _dir in "${HOME}/.local/bin" "/usr/local/bin"; do
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
    printf "\n${BOLD}IGM — Self-uninstall${NC}\n\n"
    printf "This will:\n"
    if [ "$KEEP_CONTAINERS" = "0" ]; then
        printf "  • Stop & remove all IGM containers, volumes and networks\n"
    else
        printf "  • Keep containers (skipped)\n"
    fi
    if [ "$KEEP_BINARY" = "0" ]; then
        resolve_binary_paths
        printf "  • Remove binary: %s\n" "$PATHS"
    else
        printf "  • Keep binary (skipped)\n"
    fi
    if [ "$KEEP_REPO" = "0" ]; then
        printf "  • Remove repo: %s\n" "$IGM_HOME"
    else
        printf "  • Keep repo (skipped)\n"
    fi
    printf "  • Clean shell PATH lines added by installer\n"
    printf "  • Remove legacy alias (if present)\n"
    printf "\n"
    # Detect WSL
    if grep -qi microsoft /proc/version 2>/dev/null; then
        warn "WSL detected: run uninstall.cmd on Windows to remove %%APPDATA%%\\IGM and PATH entry"
        printf "\n"
    fi

    if [ "$SKIP_CONFIRM" = "0" ]; then
        printf "${RED}${BOLD}This cannot be undone.${NC} Continue? [y/N] "
        read -r ans
        case "$ans" in
            y|Y|yes|YES) ;;
            *) printf "Aborted.\n"; exit 0 ;;
        esac
        printf "\n"
    fi

    remove_containers
    remove_binary
    clean_shell_profiles
    # Repo last — we're running from it
    remove_repo

    if command -v "$BIN_NAME" >/dev/null 2>&1; then
        warn "igm still on PATH: $(command -v "$BIN_NAME") — restart terminal or run: hash -r; unalias igm 2>/dev/null; true"
    else
        ok "igm is no longer on PATH"
    fi

    printf "\n${GREEN}${BOLD}Uninstall complete.${NC}\n\n"
    printf "Restart your terminal (or: source ~/.bashrc  /  source ~/.zshrc).\n"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        printf "Windows: also run ${BOLD}uninstall.cmd${NC} to clean %%APPDATA%%\\IGM.\n"
    fi
    printf "To reinstall, run the installer again.\n\n"
}

main "$@"
