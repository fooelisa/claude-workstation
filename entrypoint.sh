#!/bin/bash
set -euo pipefail

# Defense in depth: the orchestrator (k8s initContainer, docker-compose, etc.)
# is expected to chown these, but a restored-from-backup volume or a sidecar
# bounce could leave them root-owned. Re-chowning is cheap and idempotent.
# Paths that don't exist (e.g. /seafile when there's no sync sidecar) are
# silently skipped.
for d in /home/claude /repos /seafile; do
    [ -e "$d" ] && chown claude:claude "$d" 2>/dev/null || true
done

# Bootstrap Claude Code (native build) onto the home PVC if it's missing —
# i.e. first boot of a fresh or restored volume. The native install lives in
# ~/.local/share/claude (user-owned, persistent) and auto-updates itself, so
# this runs exactly once per volume lifetime. Failure is non-fatal: the pod
# still comes up and the install can be re-run manually in a shell.
if [ ! -x /home/claude/.local/bin/claude ]; then
    echo "claude not found on home PVC, installing native build..."
    gosu claude env HOME=/home/claude bash -c \
        'curl -fsSL https://claude.ai/install.sh | bash' \
        || echo "WARN: claude install failed; run 'curl -fsSL https://claude.ai/install.sh | bash' manually"
fi

# Drop to the unprivileged user and start ttyd. ttyd spawns a tmux client that
# attaches to (or creates) the persistent session — every browser reconnect
# resumes the same session.
exec gosu claude /usr/local/bin/ttyd \
    --writable \
    --port "${TTYD_PORT:-7681}" \
    --interface 0.0.0.0 \
    -t fontSize=14 \
    -t 'theme={"background":"#1e1e2e","foreground":"#cdd6f4"}' \
    -- tmux new -A -s "${TMUX_SESSION:-claude}"
