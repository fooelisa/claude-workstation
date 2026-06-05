#!/bin/bash
# seafile-sync sidecar entrypoint.
#
# Supervises seafile-daemon: starts it, watches for exit, restarts it.
# Container stays Ready iff this loop is alive — so a crashed daemon is a
# transient state, not a silent failure. The previous incarnation did
# `seaf-cli start; tail -F log; wait` — `tail -F` kept the container marked
# healthy even if the daemon segfaulted, so sync would die quietly.
#
# Persistent state is split across two volumes:
#   - $CLAUDE_HOME/.ccnet/  — seaf-cli's client config (init writes
#                             seafile.ini here, pointing at the data dir)
#   - /seafile/             — library checkouts + seafile-data block store
# Both must be persistent for the sync state to survive pod restarts.
#
# First-time setup is interactive — kubectl exec into this container and:
#   seaf-cli init -d /seafile
#   seaf-cli start
#   seaf-cli sync -l <library-id> -s "$SEAFILE_URL" -u "$SEAFILE_USER" \
#                 -p "$SEAFILE_TOKEN" -d /seafile/<lib-name>
#
# After that the supervisor relaunches the daemon on every pod start and
# whenever it exits unexpectedly. Previously-configured library syncs
# resume automatically.

set -euo pipefail

DATA_DIR=/seafile
CLAUDE_HOME=/home/claude
CCNET_DIR=$CLAUDE_HOME/.ccnet
DAEMON_LOG=$CCNET_DIR/logs/seafile.log

# Defense in depth — initContainer should have chowned these already.
chown claude:claude "$DATA_DIR" "$CLAUDE_HOME" 2>/dev/null || true

# `seaf-cli init` writes $CCNET_DIR/seafile.ini on first run; its presence
# is the canonical "client has been bootstrapped" marker.
if [ ! -f "$CCNET_DIR/seafile.ini" ]; then
    echo "[seafile-sync] no seaf-cli init at $CCNET_DIR/seafile.ini — waiting for interactive bootstrap"
    echo "[seafile-sync] run: kubectl -n claude exec -it deploy/claude -c seafile-sync -- gosu claude seaf-cli init -d $DATA_DIR"
    # Block so kubernetes doesn't restart-loop us before the user bootstraps.
    # `kubectl exec` still works for bootstrap.
    exec sleep infinity
fi

mkdir -p "$(dirname "$DAEMON_LOG")" 2>/dev/null || true
touch "$DAEMON_LOG" 2>/dev/null || true

# Stream the log to container stdout so `kubectl logs` shows live activity.
# This is observability only — it does NOT keep the container healthy on
# its own; the supervisor loop below does that.
gosu claude tail -F "$DAEMON_LOG" 2>/dev/null &

# Forward SIGTERM cleanly so Kubernetes graceful shutdown works.
trap 'echo "[seafile-sync] SIGTERM — stopping daemon"; gosu claude seaf-cli stop 2>/dev/null || true; exit 0' TERM INT

# Supervisor loop. seaf-cli start spawns the `seaf-daemon` binary (NOT
# `seafile-daemon` — that's the binary's friendly name, but argv[0] in the
# process table is `seaf-daemon`). seaf-cli start returns before the daemon
# is ready, so we retry-poll with a backoff before declaring failure. We
# match on `-f 'seaf-daemon --daemon'` to catch the daemon invocation
# uniquely, since the binary name alone (`seaf-daemon`) is short enough
# that other tooling could collide.
while true; do
    if ! pgrep -f 'seaf-daemon --daemon' >/dev/null; then
        echo "[seafile-sync] starting seafile-daemon"
        gosu claude seaf-cli start || echo "[seafile-sync] seaf-cli start returned non-zero"
        # Wait up to 20s for the daemon to appear, polling every 2s. seafile-daemon
        # can take a few seconds to spawn during initial setup.
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            sleep 2
            pgrep -f 'seaf-daemon --daemon' >/dev/null && break
        done
    fi

    pid=$(pgrep -f 'seaf-daemon --daemon' | head -1 || true)
    if [ -n "$pid" ]; then
        while kill -0 "$pid" 2>/dev/null; do
            sleep 10
        done
        echo "[seafile-sync] seafile-daemon (pid $pid) exited, restarting in 5s"
    else
        echo "[seafile-sync] seafile-daemon failed to start, retrying in 5s"
    fi
    sleep 5
done
