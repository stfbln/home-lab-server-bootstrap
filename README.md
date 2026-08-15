# home-lab-server-bootstrap

Public bootstrap script for a self-managing Ubuntu home lab node. Pairs
with a **private** config repo laid out in the ansible-pull convention.

Once bootstrap has run once, the private repo takes over — it installs
a systemd timer that keeps running `ansible-pull` on a schedule, so
this bootstrap is never needed again on that host.

## Bootstrap

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
2. Prompt for the SSH URL of your **private** config repo (or reuse the
   one from a prior run — see "Re-running" below).
3. Generate `/root/.ssh/home_lab_server_ed25519` and wire it into
   `/root/.ssh/config` for `github.com` (in an idempotent marked block).
4. Check whether the key already has access to the repo. If yes,
   proceed. If no, pause with step-by-step instructions for adding it
   as a **read-only deploy key** on GitHub and re-verify in a loop.
5. Clone the private repo to `/opt/home-lab-server`.
6. Write a state file at `/var/lib/home-lab-server/bootstrap.state`
   (repo URL, hostname, date) so re-runs skip the prompt.
7. Run `ansible-pull` once against `ansible/local.yml`.

## Re-running bootstrap

Bootstrap is safe to re-run — it's fully idempotent:

- The state file at `/var/lib/home-lab-server/bootstrap.state` records
  the repo URL from the successful first run. On re-run, that URL is
  reused and you're **not** re-prompted.
- The SSH key is reused if present; the ssh_config block isn't
  duplicated; the checkout is fast-forwarded instead of re-cloned.
- The GitHub deploy-key walkthrough is only shown when the key can't
  reach the repo (i.e. never on a re-run of a working host).

To **change the repo URL** or to fully reset a host, run offboard first.

## Offboarding

Reverse everything bootstrap set up:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/stfbln/home-lab-server-bootstrap/main/offboard.sh)"
```

You'll be asked to type `offboard` to confirm. The script:

- stops + disables the ansible-pull systemd timer and service, removes
  the unit files, `daemon-reload`s
- removes the checkout at `/opt/home-lab-server`
- removes the SSH deploy key files
- strips the marked block from `/root/.ssh/config`
- removes the state file at `/var/lib/home-lab-server/bootstrap.state`

It deliberately **does not** uninstall packages (git, ansible, docker,
etc.) or touch anything the ansible playbook installed. After
offboarding you can re-run bootstrap and start clean.

## What the private repo must provide

The bootstrap assumes the private repo has this shape:

```
<private-repo>/
├── ansible.cfg
└── ansible/
    ├── inventory/hosts.yml         # host(s) with ansible_connection: local
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
- Safe to re-run (see above).
- Must run as root. Reads user prompts from `/dev/tty` when interactive,
  with a subshell guard so a missing tty doesn't kill the shell under
  `set -e`.
