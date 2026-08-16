#!/usr/bin/env bash
#
# Bootstrap a fresh Ubuntu host into a self-managing ansible-pull node.
#
# What this script does:
#   1. Prompts for the private repo URL (or reuses it from a prior run).
#   2. Optionally sets the machine hostname. ansible-pull uses the
#      hostname to pick the matching entry from the inventory, so this
#      is a one-time setup done here (not from ansible itself, to avoid
#      the chicken-and-egg of the playbook renaming its own targeting key).
#   3. Installs git, ansible, openssh-client.
#   4. Generates a dedicated SSH key at /root/.ssh/home_lab_server_ed25519.
#   5. Writes an idempotent /root/.ssh/config block so root always uses
#      that key for github.com.
#   6. Tries to reach the private repo already. If it works, skips the
#      GitHub deploy-key walkthrough entirely.
#   7. Otherwise pauses with instructions to register the key as a
#      read-only deploy key, then verifies in a retry loop.
#   8. Clones the private repo to /opt/home-lab-server.
#   9. Runs `ansible-pull` once. That run installs a systemd timer; the
#      timer takes over from then on.
#
# Usage (do NOT use `curl | sudo bash` — sudo's use_pty defaults break
# interactive prompts inside a piped script):
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/stfbln/home-lab-server-bootstrap/main/bootstrap.sh)"

set -euo pipefail

REPO_DIR="/opt/home-lab-server"
SSH_KEY="/root/.ssh/home_lab_server_ed25519"
SSH_CONFIG="/root/.ssh/config"
SSH_CONFIG_BEGIN="# BEGIN home-lab-server-bootstrap"
SSH_CONFIG_END="# END home-lab-server-bootstrap"
STATE_DIR="/var/lib/home-lab-server"
STATE_FILE="$STATE_DIR/bootstrap.state"

# When piped from curl, stdin is the pipe; read from the controlling tty instead.
# The subshell test avoids killing the parent shell under `set -e` if /dev/tty
# exists but can't actually be opened (e.g. running under CI with no tty).
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
printf '  %sHome Lab Server Bootstrap%s\n' "$BOLD" "$RESET"
hr

# ---------- 1. repo URL: reuse from state file, else prompt ----------
step "Repository URL"
REPO_URL=""
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  REPO_URL="${BOOTSTRAP_REPO_URL:-}"
  if [[ -n "$REPO_URL" ]]; then
    ok "Reusing repo from previous bootstrap: $REPO_URL"
    info "To change repo, run offboard.sh first."
  fi
fi
if [[ -z "$REPO_URL" ]]; then
  while true; do
    printf '  Enter the SSH URL of the private config repo\n'
    printf '  (e.g. %sgit@github.com:you/home-lab-server.git%s): ' "$DIM" "$RESET"
    read -r REPO_URL || true
    if [[ -n "${REPO_URL:-}" ]]; then
      break
    fi
    warn "Repo URL is required — try again."
  done
  ok "Using $REPO_URL"
fi

# ---------- 2. hostname (one-time; ansible-pull targets by hostname) -
step "Hostname"
CURRENT_HOSTNAME="$(hostname)"
info "Current hostname: $CURRENT_HOSTNAME"
printf '  ansible-pull uses the hostname to pick the matching inventory\n'
printf '  entry (ansible/inventory/hosts.yml). Change it? [y/N]: '
read -r CHANGE_HOSTNAME || true
if [[ "${CHANGE_HOSTNAME:-}" =~ ^[Yy]$ ]]; then
  while true; do
    printf '  New hostname: '
    read -r NEW_HOSTNAME || true
    if [[ -z "${NEW_HOSTNAME:-}" ]]; then
      warn "Hostname is required — try again (or Ctrl+C to abort)."
      continue
    fi
    # RFC 1123 single label: start/end alphanumeric, dashes allowed inside, ≤63 chars.
    if [[ ! "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
      warn "Invalid hostname — must be ≤63 chars, alphanumerics and dashes, not starting/ending with a dash."
      continue
    fi
    break
  done
  hostnamectl set-hostname "$NEW_HOSTNAME"
  # Keep /etc/hosts in sync so `sudo` and local resolvers don't warn.
  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >> /etc/hosts
  fi
  ok "Hostname set to $NEW_HOSTNAME"
else
  ok "Keeping current hostname: $CURRENT_HOSTNAME"
fi

# ---------- 3. install packages --------------------------------------
step "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git ansible openssh-client ca-certificates
ok "Installed git, ansible, openssh-client"

# ---------- 4. dedicated SSH key -------------------------------------
step "Preparing SSH deploy key"
install -d -m 0700 /root/.ssh
if [[ -f "$SSH_KEY" ]]; then
  ok "Key already exists at $SSH_KEY (reusing)"
else
  ssh-keygen -t ed25519 -N "" -C "home-lab-server@$(hostname)" -f "$SSH_KEY" >/dev/null
  ok "Generated $SSH_KEY"
fi

# ---------- 5. ssh config entry (idempotent via markers) -------------
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"
if grep -qF "$SSH_CONFIG_BEGIN" "$SSH_CONFIG"; then
  ok "SSH config for github.com already points at this key"
else
  cat >> "$SSH_CONFIG" <<EOF

$SSH_CONFIG_BEGIN
Host github.com
  HostName github.com
  User git
  IdentityFile $SSH_KEY
  IdentitiesOnly yes
$SSH_CONFIG_END
EOF
  ok "Wrote SSH config for github.com → $SSH_KEY"
fi

# ---------- 6. check repo access; only walk through GitHub if needed -
check_repo_access() {
  GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10" \
    git ls-remote --quiet "$REPO_URL" HEAD >/dev/null 2>&1
}

step "Checking access to the private repo"
if check_repo_access; then
  ok "Key is already authorized on this repo — skipping GitHub setup"
else
  info "Key is not yet authorized on the repo."
  PUBKEY=$(cat "${SSH_KEY}.pub")
  echo
  hr
  printf '  %sADD THE KEY BELOW AS A DEPLOY KEY%s\n\n' "$BOLD" "$RESET"
  printf '    1. Open the private repo on GitHub in a browser.\n'
  printf '    2. Go to: %sSettings → Deploy keys → "Add deploy key"%s\n' "$BOLD" "$RESET"
  printf '    3. Title:  home-lab-server (%s)\n' "$(hostname)"
  printf '    4. Key:    paste the block below (all one line)\n'
  printf '    5. Leave "Allow write access" %sUNCHECKED%s\n' "$BOLD" "$RESET"
  printf '    6. Click "Add key"\n\n'
  printf '%s\n' "$PUBKEY"
  hr
  echo
  while true; do
    printf '  Press ENTER once the deploy key is added (Ctrl+C to abort)... '
    read -r _ || true
    info "Verifying..."
    if check_repo_access; then
      ok "Repo access confirmed"
      break
    fi
    fail "Still no access. Common causes: key not saved, wrong repo, wrong key pasted."
  done
fi

# ---------- 7. clone repo --------------------------------------------
step "Cloning private repo to $REPO_DIR"
if [[ -d "$REPO_DIR/.git" ]]; then
  git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
  git -C "$REPO_DIR" fetch --quiet origin
  git -C "$REPO_DIR" pull --ff-only --quiet
  ok "Fast-forwarded existing clone"
else
  git clone --quiet "$REPO_URL" "$REPO_DIR"
  ok "Cloned repo"
fi

# ---------- 8. persist state so future re-runs skip the prompt -------
install -d -m 0755 "$STATE_DIR"
cat > "$STATE_FILE" <<EOF
# Managed by bootstrap.sh — delete via offboard.sh, not by hand.
BOOTSTRAP_VERSION=1
BOOTSTRAP_REPO_URL="$REPO_URL"
BOOTSTRAP_HOSTNAME="$(hostname)"
BOOTSTRAP_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
chmod 0644 "$STATE_FILE"
ok "Wrote state to $STATE_FILE"

# ---------- 9. run ansible-pull once --------------------------------
step "Running ansible-pull (this installs the systemd timer)"
if /usr/bin/ansible-pull \
    --url "$REPO_URL" \
    --directory "$REPO_DIR" \
    --inventory ansible/inventory/hosts.yml \
    ansible/local.yml; then
  ok "First run completed"
else
  fail "ansible-pull failed — inspect the output above"
  exit 1
fi

echo
hr
printf '  %s%sBootstrap complete.%s\n' "$GREEN" "$BOLD" "$RESET"
hr
cat <<EOF

  The ansible_pull role has installed a systemd timer. This host will
  now reconcile itself on schedule — bootstrap is never needed again.

  Useful commands:
    ${DIM}systemctl status ansible-pull.timer${RESET}
    ${DIM}systemctl list-timers ansible-pull.timer${RESET}
    ${DIM}journalctl -u ansible-pull.service -n 100${RESET}
    ${DIM}journalctl -u ansible-pull.service -f${RESET}

EOF
