# home-lab-server-bootstrap

Public bootstrap script for a self-managing Ubuntu home lab node. Pairs
with a **private** config repo laid out in the ansible-pull convention.

Once bootstrap has run once, the private repo takes over — it installs
a systemd timer that keeps running `ansible-pull` on a schedule, so
this bootstrap is never needed again on that host.

## Usage

On a fresh Ubuntu server:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/stfbln/home-lab-server-bootstrap/main/bootstrap.sh)"
```

> **Why not `curl | sudo bash`?** On Ubuntu 22.04+ sudoers defaults to
> `use_pty`, which gives the child process a private pty. When bash
> reads its script from a pipe, its `/dev/tty` points at that private
> pty rather than your terminal, so the script's interactive prompts
> hang forever waiting for input. The `bash -c "$(curl …)"` form
> downloads the script in your interactive shell first and passes it
> via argv, leaving stdin free for the prompts.

The script will:

1. Install `git`, `ansible`, `openssh-client`.
2. Prompt for the SSH URL of your **private** config repo.
3. Generate `/root/.ssh/id_ed25519` and pause with step-by-step
   instructions for adding it as a **read-only deploy key** on GitHub.
4. Verify SSH access to GitHub — retries on failure so you can fix and
   continue without re-running the whole script.
5. Clone the private repo to `/opt/home-lab-server`.
6. Run `ansible-pull` once against `ansible/local.yml`.

## What the private repo must provide

The bootstrap assumes the private repo has this shape:

```
<private-repo>/
├── ansible.cfg
└── ansible/
    ├── inventory/hosts.yml         # targeting localhost
    ├── local.yml                   # entry-point playbook
    └── roles/
        └── ansible_pull/           # installs & enables the systemd timer
```

The `ansible_pull` role (or whatever you call it) is what makes the
node self-managing after the one-shot bootstrap run. Without it, the
server would apply the playbook once and never again.

## Bootstrap safety

- The script itself contains **no secrets**. Everything sensitive (the
  SSH deploy key) is generated on the target host and stays there.
- Safe to re-run: reuses an existing SSH key, fast-forwards an existing
  clone, and `ansible-pull` is idempotent by design.
- Must run as root (uses `sudo bash`). Reads user prompts from
  `/dev/tty` so `curl | bash` doesn't break interactivity.
