#!/usr/bin/env bash
#
# Serve the site from this checkout to preview it in a browser.
#
# Usage:
#   ./run.sh
#
# Port (project number 200, main checkout):
#   20000  site — http://claywork.localhost or http://localhost:20000
#
# A parallel clone (a sibling checkout named dev-<name>-<port>) takes a free
# port from 20010 up (the port table in notes is the source of truth) and
# sets it, with a host name of its own, in an untracked .envrc.local:
#   export PORT=<port>
#   export PROXY_HOST=claywork-<name>.localhost
# The port comes from that file or the default above, never from the caller's
# environment. A clone without its own is refused: it would kill the main
# checkout's server, or take over its dev-proxy route and delete it on exit.
#
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
	"") ;;
	-h|--help)
		sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "Usage: $(basename "$0")" >&2
		exit 2
		;;
esac

unset PORT PROXY_HOST
if [ -f .envrc.local ]; then
	# shellcheck source=/dev/null
	. ./.envrc.local
elif [[ $(basename "$PWD") =~ -[0-9]{4,5}$ ]]; then
	echo "ERROR: this parallel clone has no .envrc.local (see the header of run.sh)." >&2
	exit 1
fi
PORT="${PORT:-20000}"
PROXY_HOST="${PROXY_HOST:-claywork.localhost}"

# A clone must not fall back to the main checkout's port or host name.
if [ -f .envrc.local ]; then
	case "$PORT:$PROXY_HOST" in
		20000:* | *:claywork.localhost)
			echo "ERROR: .envrc.local sets no port and host name of this clone's own" >&2
			echo "  (see the header of run.sh)." >&2
			exit 1
			;;
	esac
fi

# Kill whatever listens on the port, not its clients (a browser showing the site).
PID=$(lsof -ti tcp:"$PORT" -sTCP:LISTEN 2>/dev/null || true)
if [ -n "$PID" ]; then
	echo "Port $PORT in use by PID $PID, killing..."
	kill -9 $PID 2>/dev/null || true
	sleep 1
fi

# Start dev-proxy in background (skip if missing); remove its route on exit.
proxy_pid=""
cleanup() {
	if [ -n "$proxy_pid" ] && kill -0 "$proxy_pid" 2>/dev/null; then
		kill "$proxy_pid" 2>/dev/null || true
		wait "$proxy_pid" 2>/dev/null || true
	fi
}
trap cleanup EXIT INT TERM

base="http://localhost:$PORT"
if command -v dev-proxy >/dev/null 2>&1; then
	echo "Starting dev-proxy: http://$PROXY_HOST -> :$PORT"
	dev-proxy "$PROXY_HOST" "$PORT" >/dev/null 2>&1 &
	proxy_pid=$!
	sleep 1
	if kill -0 "$proxy_pid" 2>/dev/null; then
		base="http://$PROXY_HOST"
	else
		echo "Note: dev-proxy could not start (is Caddy running?); use $base." >&2
		proxy_pid=""
	fi
else
	echo "Note: dev-proxy not found, skipping reverse proxy setup." >&2
fi

echo "Serving the site on $base (Ctrl+C to stop)"
python3 - "$PORT" "$PWD" <<'EOF'
import functools
import http.server
import os
import subprocess
import sys


class Site(http.server.SimpleHTTPRequestHandler):
    """Serve only what GitHub Pages publishes: files git tracks or would
    track, but no dotfiles and nothing git ignores. The proxy's host name
    also reaches this server from other machines, and the checkout holds
    files that are never published."""

    def send_head(self):
        path = self.translate_path(self.path)
        rel = os.path.relpath(path, self.directory)
        parts = [] if rel == "." else rel.split(os.sep)
        real = os.path.realpath(path)
        inside = real == self.directory or real.startswith(self.directory + os.sep)
        hidden = any(part.startswith(".") for part in parts)
        # check-ignore exits 0 when ignored, 1 when not, 128 beyond a symlink.
        ignored = bool(parts) and subprocess.run(
            ["git", "check-ignore", "-q", "--", rel],
            cwd=self.directory, stderr=subprocess.DEVNULL).returncode != 1
        if not inside or hidden or ignored:
            self.send_error(404)
            return None
        return super().send_head()

    def list_directory(self, path):
        self.send_error(404)
        return None

    # An edited page shows as it is now on reload: the browser keeps none.
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


port, root = int(sys.argv[1]), os.path.realpath(sys.argv[2])
server = http.server.ThreadingHTTPServer(
    ("127.0.0.1", port), functools.partial(Site, directory=root))
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
EOF
