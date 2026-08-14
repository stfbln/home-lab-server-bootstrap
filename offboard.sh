#!/usr/bin/env bash
#
# Offboard: reverse what bootstrap.sh set up so the host can be
# re-bootstrapped from scratch (or handed to another purpose).
#
# What this removes:
#   - the ansible-pull systemd timer + service (stopped, disabled, deleted)
#   - the checkout at /opt/home-lab-server
#   - the SSH deploy key at /root/.ssh/home_lab_server_ed25519(.pub)
#   - the marked block from /root/.ssh/config
#   - the state file at /var/lib/home-lab-server/bootstrap.state
#
# What it does NOT touch:
#   - the installed packages (git, ansible, openssh-client)
#   - Docker or anything the ansible playbook installed
#   - anything under /root outside the paths above
#
# Usage:
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/stfbln/home-lab-server-bootstrap/main/offboard.sh)"

set -euo pipefail

REPO_DIR="/opt/home-lab-server"
SSH_KEY="/root/.ssh/home_lab_server_ed25519"
SSH_CONFIG="/root/.ssh/config"
SSH_CONFIG_BEGIN="# BEGIN home-lab-server-bootstrap"
SSH_CONFIG_END="# END home-lab-server-bootstrap"
STATE_DIR="/var/lib/home-lab-server"
STATE_FILE="$STATE_DIR/bootstrap.state"

if [[ ! -t 0 ]] && ( : </dev/tty ) 2>/dev/null; then
  exec </dev/tty
fi

# ---------- output helpers -------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'
  YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'
else
  BOLD=""; DIM=""; RESET=""; GREEN=""; RED=""; YELLOW=""; BLUE=""
fi
CHECK="${GREEN}✓${RESET}"
CROSS="${RED}✗${RESET}"
WARN_SYM="${YELLOW}⚠${RESET}"
ARROW="${BLUE}→${RESET}"

step()  { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }
info()  { printf '  %s %s\n' "$ARROW" "$*"; }
ok()    { printf '  %s %s\n' "$CHECK" "$*"; }
fail()  { printf '  %s %s\n' "$CROSS" "$*" >&2; }
warn()  { printf '  %s %s\n' "$WARN_SYM" "$*"; }
hr()    { printf '%s%s%s\n' "$DIM" "────────────────────────────────────────────────────────────────" "$RESET"; }
# ---------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  fail "This script must be run as root (use sudo)."
  exit 1
fi

hr
printf '  %sHome Lab Server Offboard%s\n' "$BOLD" "$RESET"
hr

step "This will remove"
info "systemd:  /etc/systemd/system/ansible-pull.{service,timer}"
info "checkout: $REPO_DIR"
info "SSH key:  $SSH_KEY(.pub)"
info "SSH cfg:  marked block in $SSH_CONFIG"
info "state:    $STATE_FILE"
echo
warn "Packages (git, ansible, docker, etc.) will NOT be uninstalled."

echo
printf '  Type %soffboard%s to confirm: ' "$BOLD" "$RESET"
read -r CONFIRM || true
if [[ "${CONFIRM:-}" != "offboard" ]]; then
  fail "Aborted."
  exit 1
fi

step "Stopping and removing systemd units"
systemctl disable --now ansible-pull.timer >/dev/null 2>&1 || true
systemctl stop ansible-pull.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/ansible-pull.service /etc/systemd/system/ansible-pull.timer
systemctl daemon-reload
ok "systemd units removed"

step "Removing checkout"
if [[ -d "$REPO_DIR" ]]; then
  rm -rf "$REPO_DIR"
  ok "$REPO_DIR removed"
else
  ok "$REPO_DIR was not present"
fi

step "Removing SSH deploy key"
if [[ -f "$SSH_KEY" || -f "${SSH_KEY}.pub" ]]; then
  rm -f "$SSH_KEY" "${SSH_KEY}.pub"
  ok "SSH key files removed"
else
  ok "SSH key was not present"
fi

step "Cleaning SSH config"
if [[ -f "$SSH_CONFIG" ]] && grep -qF "$SSH_CONFIG_BEGIN" "$SSH_CONFIG"; then
  sed -i "\|^${SSH_CONFIG_BEGIN}\$|,\|^${SSH_CONFIG_END}\$|d" "$SSH_CONFIG"
  ok "Marked block removed from $SSH_CONFIG"
else
  ok "No marked block to remove"
fi

step "Removing state file"
if [[ -f "$STATE_FILE" ]]; then
  rm -f "$STATE_FILE"
  rmdir --ignore-fail-on-non-empty "$STATE_DIR" 2>/dev/null || true
  ok "State file removed"
else
  ok "State file was not present"
fi

echo
hr
printf '  %s%sOffboard complete.%s\n' "$GREEN" "$BOLD" "$RESET"
hr
cat <<EOF

  This host is back to (roughly) its pre-bootstrap state. Re-run
  bootstrap to start fresh:

    ${DIM}sudo bash -c "\$(curl -fsSL https://raw.githubusercontent.com/stfbln/home-lab-server-bootstrap/main/bootstrap.sh)"${RESET}

EOF
