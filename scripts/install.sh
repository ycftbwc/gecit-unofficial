#!/usr/bin/env bash
#
# gecit local compile & install script
#
# Install & Start:
#   sudo ./scripts/install.sh
#
# Skip auto-start:
#   sudo ./scripts/install.sh --no-start
#
# Uninstall:
#   sudo ./scripts/install.sh --uninstall

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="${PREFIX}/bin"
BIN_PATH="${BIN_DIR}/gecit"
UNIT_PATH="/etc/systemd/system/gecit.service"
MIN_KERNEL_MAJOR=5
MIN_KERNEL_MINOR=10

# ---------------------------------------------------------------------------
# Output helpers (ANSI only)
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi

step() { printf "\n  ${BOLD}[%s/%s]${NC} %s\n" "$1" "$2" "$3"; }
ok()   { printf "  ${GREEN}OK${NC}   %s\n" "$*"; }
info() { printf "  ${CYAN}..${NC}   %s\n" "$*"; }
warn() { printf "  ${YELLOW}WARN${NC} %s\n" "$*"; }
err()  { printf "\n  ${RED}ERROR${NC} %s\n\n" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
gecit local installer

Usage:
  sudo ./scripts/install.sh [flags]

Flags:
  --no-start       install but don't start the service
  --no-enable      install but don't enable or start the service
  --uninstall      stop, disable, and remove gecit
  -h, --help       show this help

Environment:
  PREFIX=/path     install root (default: /usr/local; binary at $PREFIX/bin/gecit)
  NO_COLOR=1       disable ANSI colors

EOF
    exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

NO_START=0
NO_ENABLE=0
UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --no-start)   NO_START=1 ;;
        --no-enable)  NO_ENABLE=1; NO_START=1 ;;
        --uninstall)  UNINSTALL=1 ;;
        -h|--help)    usage 0 ;;
        *)            printf "Unknown flag: %s\n\n" "$1" >&2; usage 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    err "Must run as root. Re-run with: sudo ./scripts/install.sh"
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

detect_os() {
    case "$(uname -s)" in
        Linux) OS=linux ;;
        *) err "Only Linux is supported by this installer (got $(uname -s)). See README for macOS/Windows setup." ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *) err "Unsupported architecture: $(uname -m). Supported: amd64, arm64." ;;
    esac
}

detect_kernel() {
    local kver major minor
    kver="$(uname -r)"
    major="${kver%%.*}"
    minor="${kver#*.}"; minor="${minor%%.*}"
    if [ "$major" -lt "$MIN_KERNEL_MAJOR" ] || \
       { [ "$major" -eq "$MIN_KERNEL_MAJOR" ] && [ "$minor" -lt "$MIN_KERNEL_MINOR" ]; }; then
        err "gecit needs Linux kernel ${MIN_KERNEL_MAJOR}.${MIN_KERNEL_MINOR}+ for eBPF sock_ops (you have ${kver})."
    fi
}

detect_systemd() {
    if [ ! -d /run/systemd/system ]; then
        err "systemd not detected (no /run/systemd/system). This installer only configures systemd."
    fi
}

require_tools() {
    local missing=()
    for t in make go clang llvm-strip install systemctl awk; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        err "Missing required build tools: ${missing[*]}"
    fi
}

check_dir() {
    if [ ! -f "Makefile" ] || [ ! -d "cmd/gecit" ]; then
        err "Must run this script from the root of the gecit repository."
    fi
}

# ---------------------------------------------------------------------------
# Existing install handling
# ---------------------------------------------------------------------------

backup_existing() {
    local found=0
    if systemctl is-active --quiet gecit 2>/dev/null; then
        info "Stopping running gecit service..."
        systemctl stop gecit
        found=1
    fi
    if [ -f "$UNIT_PATH" ]; then
        info "Backing up existing unit to ${UNIT_PATH}.bak"
        cp -p "$UNIT_PATH" "${UNIT_PATH}.bak"
        found=1
    fi
    if [ -f "$BIN_PATH" ]; then
        info "Backing up existing binary to ${BIN_PATH}.bak"
        cp -p "$BIN_PATH" "${BIN_PATH}.bak"
        found=1
    fi
    if [ "$found" -eq 0 ]; then
        info "No existing install found"
    fi
}

# ---------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------

compile_binary() {
    info "Compiling optimized gecit-${OS}-${ARCH} locally..."
    if ! make "gecit-${OS}-${ARCH}"; then
        err "Compilation failed. Check the output above for details."
    fi
    ok "Compilation verified"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

install_binary() {
    install -d -m 0755 "$BIN_DIR"
    install -m 0755 "./bin/gecit-${OS}-${ARCH}" "$BIN_PATH"
    ok "Installed binary at ${BIN_PATH}"
}

write_unit() {
    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=gecit DPI bypass (eBPF)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} run
ExecStopPost=${BIN_PATH} cleanup
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$UNIT_PATH"
    ok "Wrote systemd unit at ${UNIT_PATH}"
}

activate_service() {
    systemctl daemon-reload
    if [ "$NO_ENABLE" -eq 1 ]; then
        info "Skipping enable + start (--no-enable)"
        return
    fi
    systemctl enable gecit >/dev/null 2>&1 || warn "systemctl enable returned non-zero"
    ok "Service enabled"
    if [ "$NO_START" -eq 1 ]; then
        info "Skipping start (--no-start)"
        return
    fi
    if ! systemctl start gecit 2>/dev/null; then
        warn "systemctl start gecit failed. Check: journalctl -u gecit -n 50"
        return
    fi
    sleep 1
    if systemctl is-active --quiet gecit; then
        ok "Service active"
    else
        warn "Service did not become active. Check: journalctl -u gecit -n 50"
    fi
}

print_install_summary() {
    local active
    active="$(systemctl is-active gecit 2>/dev/null || true)"
    [ -z "$active" ] && active="not running"
    printf "\n"
    printf "  %sgecit (local build) installed%s\n" "$BOLD" "$NC"
    printf "  ----------------------------------------\n"
    printf "  binary:   %s\n" "$BIN_PATH"
    printf "  unit:     %s\n" "$UNIT_PATH"
    printf "  status:   %s\n" "$active"
    printf "\n"
    printf "  %sCommon commands%s\n" "$BOLD" "$NC"
    printf "    sudo systemctl status gecit\n"
    printf "    sudo systemctl restart gecit\n"
    printf "    sudo journalctl -u gecit -f\n"
    printf "    sudo gecit status\n"
    printf "\n"
    printf "  %sCustomize flags%s (--fake-ttl, --doh-upstream, --ports, ...)\n" "$BOLD" "$NC"
    printf "    sudo systemctl edit gecit\n"
    printf "\n"
    printf "  %sUninstall%s\n" "$BOLD" "$NC"
    printf "    sudo ./scripts/install.sh --uninstall\n"
    printf "\n"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

run_uninstall() {
    info "Uninstalling gecit..."
    if systemctl is-active --quiet gecit 2>/dev/null; then
        info "Stopping service (ExecStopPost runs gecit cleanup to restore DNS state)..."
        systemctl stop gecit
    elif [ -x "$BIN_PATH" ]; then
        info "Service not running; invoking gecit cleanup directly..."
        "$BIN_PATH" cleanup || warn "gecit cleanup returned non-zero (may be benign)"
    fi
    if systemctl is-enabled --quiet gecit 2>/dev/null; then
        systemctl disable gecit >/dev/null 2>&1 || true
    fi
    rm -f "$UNIT_PATH" "${UNIT_PATH}.bak"
    rm -f "$BIN_PATH" "${BIN_PATH}.bak"
    systemctl daemon-reload
    ok "gecit removed"
    printf "\n"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    printf "\n  %sgecit local installer%s\n" "$BOLD" "$NC"
    printf "  ----------------------------------------\n"

    if [ "$UNINSTALL" -eq 1 ]; then
        run_uninstall
        return
    fi

    step 1 6 "Preflight"
    check_dir
    detect_os
    detect_arch
    detect_kernel
    detect_systemd
    require_tools
    ok "${OS}/${ARCH}, kernel $(uname -r), systemd present"

    step 2 6 "Compile locally"
    compile_binary

    step 3 6 "Back up existing install (if any)"
    backup_existing

    step 4 6 "Install binary"
    install_binary

    step 5 6 "Write systemd unit"
    write_unit

    step 6 6 "Activate service"
    activate_service

    print_install_summary
}

main "$@"
