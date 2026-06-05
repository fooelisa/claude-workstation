# claude-workstation

A container image for a phone- and laptop-accessible
[Claude Code](https://docs.claude.com/claude-code) workstation. Runs
[`ttyd`](https://github.com/tsl0922/ttyd) over a persistent
[`tmux`](https://github.com/tmux/tmux) session — open the URL on any device
with a browser, drop into your session exactly where you left it.

## What's inside

- `ttyd` (web terminal) on port `7681`
- `tmux` with a polished mobile-friendly config (mouse mode, `Ctrl-a` prefix,
  Catppuccin Mocha)
- `claude` CLI ([Anthropic Claude Code](https://docs.claude.com/claude-code))
  — not baked into the image; the entrypoint bootstraps the self-updating
  native build onto the home volume on first boot
- Common dev tooling: `git`, `gh`, `kubectl`, `sops`, `age`, `python3`, `jq`,
  `vim`, `less`, `openssh-client`

Runs as the unprivileged `claude` user (UID 1000) via `gosu`.

## Why a custom image

There's no upstream container for Claude Code, and "browser shell that survives
mobile network blips" needs both `tmux` (for session persistence) and a web
terminal frontend. Combining them in one minimal image is small and
predictable: Node 22 slim base plus a handful of statically-linked CLIs.

## Build

`linux/arm64` by default. GitHub Actions builds on every push to `main` and
pushes to GHCR:

```
ghcr.io/<your-account>/claude-workstation:main      # mutable, tracks main
ghcr.io/<your-account>/claude-workstation:<sha>     # immutable, one per commit
```

To add amd64, flip the `platforms:` line in `.github/workflows/build.yaml`.

Local build:

```
docker buildx build --platform linux/arm64 -t claude-workstation:dev .
```

## Run

The simplest possible smoke test:

```
docker run --rm -it -p 7681:7681 \
  -v claude-home:/home/claude \
  -v claude-repos:/repos \
  ghcr.io/<your-account>/claude-workstation:main
```

Then open `http://localhost:7681`.

For real use, you almost certainly want to put this behind some form of
auth/transport security — a tailnet, a reverse proxy with SSO, an SSH tunnel,
etc. ttyd has no auth surface of its own beyond optional HTTP basic auth (`-c
user:pass`); the design here assumes the *network path* is the access control.

A minimal Kubernetes Deployment skeleton is at
[`examples/deployment.yaml`](./examples/deployment.yaml).

## Configuration

Knobs exposed via env:

| Env | Default | What |
|-----|---------|------|
| `TTYD_PORT` | `7681` | Port ttyd listens on |
| `TMUX_SESSION` | `claude` | Name of the persistent tmux session |

Mount points the image expects:

- `/home/claude` — persistent home directory. Claude Code config, plugins,
  skills, credentials, MCP state, SSH keys, dotfiles. Make this a volume.
- `/repos` — where you'll clone repos. Make this a volume.
- `/seafile` — *optional*, only when running `seafile-sync.sh` as a sidecar to
  sync a Seafile library into the workstation. Make this a volume if used,
  skip otherwise — the entrypoint chown is `[ -e ]`-guarded.

All mounted directories need to be writable by UID 1000. The entrypoint will
`chown` whichever of the above paths actually exist at startup as defense in
depth, but your orchestrator should set ownership too (Kubernetes
initContainer, docker-compose `user:`, etc.).

### Seafile sync sidecar (optional)

The image ships `/usr/local/bin/seafile-sync.sh`, a small wrapper that runs
[`seaf-cli`](https://help.seafile.com/syncing_client/linux-cli/)'s daemon
against a Seafile server and keeps a library checkout under `/seafile`. To
use it, run the same image as a *second* container in the pod with
`command: ["/usr/local/bin/seafile-sync.sh"]` and mount a `/seafile` volume
into both containers. seaf-cli's client config (`~/.ccnet/seafile.ini`) is
written on first `seaf-cli init -d /seafile` — that's an interactive
one-time step. After that the daemon resumes any previously-configured
library syncs on every restart.

## tmux config

Lives at `/etc/tmux.conf` (not `~/.tmux.conf`) so a volume mount on
`/home/claude` doesn't shadow it. Highlights:

- `Ctrl-a` prefix (easier than `Ctrl-b` on a phone keyboard)
- `set -g mouse on` — tap the status bar to switch windows, drag dividers to
  resize panes, touch-scroll the scrollback
- Catppuccin Mocha palette, status bar shows the window list always
- Windows numbered from 1 (matches the prefix-1..9 chord)
- Alt+arrow to navigate windows without the prefix

A user-level `~/.tmux.conf` is read after the system one and overrides it.

## First-time bootstrap

After your pod/container is up, the user has to log in to Claude Code once
(the OAuth token lands in `/home/claude/.claude/credentials.json` and persists
across restarts). The interactive flow works fine over ttyd:

```
# Inside the browser terminal:
claude /login
```

Plugins, MCPs, and skills can either be installed fresh via `claude /plugin
install …` or copied from an existing setup (see `kubectl cp` or `docker cp`).

## Security notes

- The container holds whatever you authenticate it with: Claude OAuth token,
  GitHub PAT, SSH private keys, MCP credentials, possibly `kubectl` cluster
  credentials. Treat the volume backing `/home/claude` as sensitive.
- ttyd has no built-in HTTPS, no built-in auth. Put it behind a reverse proxy
  (Traefik, nginx, Caddy), a VPN (Tailscale, Headscale, WireGuard), or an
  identity-aware tunnel (Cloudflare Access, etc.).
- The single tmux session is a single concurrent user. Two browsers attached
  to the same session see each other's input — fine for "Mac and phone at the
  same time, same task," surprising otherwise.

## License

MIT.
