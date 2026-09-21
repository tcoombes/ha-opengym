#!/bin/sh
# ---------------------------------------------------------------------------
# openGym API add-on entrypoint
#
# Supervisor writes the add-on's configuration to /data/options.json. This
# script reads it, exports the environment variables openGym expects, then
# hands over to the start command baked into the upstream image.
#
# No jq, no bashio - the upstream image is not a Home Assistant base image, so
# we parse the (flat) options file with grep/sed and stay dependency-free.
# ---------------------------------------------------------------------------
set -e

OPTIONS=/data/options.json

log() { echo "[openGym API] $*"; }

# opt <key> <default> - reads a flat string, number or boolean from options.json
opt() {
    _key="$1"
    _def="$2"
    _hit=$(grep -o "\"${_key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$OPTIONS" 2>/dev/null | head -n 1)
    if [ -n "$_hit" ]; then
        printf '%s' "$_hit" | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/'
        return 0
    fi
    _hit=$(grep -o "\"${_key}\"[[:space:]]*:[[:space:]]*[0-9A-Za-z.]*" "$OPTIONS" 2>/dev/null | head -n 1)
    if [ -n "$_hit" ]; then
        printf '%s' "$_hit" | sed 's/.*:[[:space:]]*//'
        return 0
    fi
    printf '%s' "$_def"
}

RP_ID="$(opt rp_id gym.tcoombes.co.uk)"
ORIGIN="$(opt origin https://gym.tcoombes.co.uk)"
RP_NAME="$(opt rp_name openGym)"
API_PORT="$(opt api_port 3000)"

# /data is the add-on's persistent volume: it survives restarts, rebuilds and
# HAOS updates, and it is included in Home Assistant backups. We keep openGym's
# files in a subfolder so they don't sit next to Supervisor's options.json.
DATA_DIR=/data/opengym
mkdir -p "$DATA_DIR"

PORT="$API_PORT"
export RP_ID ORIGIN RP_NAME PORT API_PORT DATA_DIR

log "RP_ID=$RP_ID"
log "ORIGIN=$ORIGIN"
log "RP_NAME=$RP_NAME"
log "PORT=$PORT"
log "DATA_DIR=$DATA_DIR"

# --- optional settings (docs.html#env) --------------------------------------
# Only exported when set, so anything left blank keeps openGym's own default.
# set_env <ENV_NAME> <option_key> [bool]
set_env() {
    _v="$(opt "$2" "")"
    [ -n "$_v" ] && [ "$_v" != "null" ] || return 0
    if [ "${3:-}" = bool ]; then
        case "$_v" in
            true) _v=1 ;;
            false) _v=0 ;;
        esac
    fi
    export "$1=$_v"
    log "$1=$_v"
}

set_env SESSION_DAYS         session_days
set_env ADMIN_UIDS           admin_uids
set_env INVITE_ONLY          invite_only    bool
set_env ALLOW_GUEST          allow_guest    bool
set_env AUDIT_LOG            audit_log      bool
set_env AUDIT_MAX            audit_max
set_env AUDIT_DAYS           audit_days
set_env AUDIT_IP             audit_ip
set_env VAPID_SUBJECT        vapid_subject
set_env COACH_DISABLED       coach_disabled bool
set_env COACH_JOB_TIMEOUT_MS coach_job_timeout_ms

# extra_env: ["KEY=value", ...] for anything upstream adds later. Applied last,
# so it can also override the typed options above.
EXTRA_TMP="$(mktemp)"
tr -d '\n' < "$OPTIONS" 2>/dev/null \
    | sed -n 's/.*"extra_env"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' \
    | grep -o '"[^"]*"' | sed 's/^"//; s/"$//' > "$EXTRA_TMP" || true
while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    _k="${kv%%=*}"
    if ! printf '%s' "$kv" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; then
        log "extra_env: ignoring '$kv' (needs KEY=value)"
    elif [ "$_k" = "DATA_DIR" ]; then
        log "extra_env: ignoring DATA_DIR (the add-on pins it to /data/opengym)"
    else
        export "$kv"
        log "extra_env: $_k set"
    fi
done < "$EXTRA_TMP"
rm -f "$EXTRA_TMP"

# --- MCP snapshot export ----------------------------------------------------
# openGym's MCP server runs on your PC and reads data files directly, which it
# can't do inside this add-on. When enabled, a background loop publishes a
# scrubbed read-only snapshot to /share/opengym-mcp (see mcp-export.mjs for
# exactly what is and isn't copied). It keeps running after the exec below.
if [ "$(opt mcp_export false)" = "true" ]; then
    MCP_DIR=/share/opengym-mcp
    MCP_MINUTES="$(opt mcp_export_minutes 5)"
    log "MCP export: snapshot to $MCP_DIR every ${MCP_MINUTES} min"
    (
        while true; do
            node /mcp-export.mjs "$DATA_DIR" "$MCP_DIR" || log "MCP export run failed"
            sleep $((MCP_MINUTES * 60))
        done
    ) &
fi

# --- hand over to the upstream start command --------------------------------
# Setting ENTRYPOINT in our Dockerfile makes Docker discard the base image's
# CMD, so "$@" is normally empty. WORKDIR *is* inherited, so we start in the
# upstream working directory and find the app from there.
#
# If you know the exact command, put it here and discovery is skipped:
START_CMD=""

export PATH="$(pwd)/node_modules/.bin:$PATH"

if [ -n "$START_CMD" ]; then
    log "starting (START_CMD): $START_CMD"
    exec sh -c "exec $START_CMD"
fi

if [ "$#" -gt 0 ]; then
    log "starting (inherited): $*"
    exec "$@"
fi

log "workdir: $(pwd)"

# 1. The author's own "start" script, exec'd directly rather than via npm so
#    node becomes PID 1 and add-on stop/restart signals reach it.
if [ -f package.json ]; then
    START_SCRIPT=$(sed -n 's/^[[:space:]]*"start"[[:space:]]*:[[:space:]]*"\(.*\)",\{0,1\}[[:space:]]*$/\1/p' package.json | head -n 1)
    if [ -n "$START_SCRIPT" ]; then
        log "starting (package.json start): $START_SCRIPT"
        exec sh -c "exec $START_SCRIPT"
    fi
fi

# 2. Common compiled entry points.
for f in dist/index.js dist/server.js dist/main.js build/index.js \
         server.js index.js main.js; do
    if [ -f "$f" ]; then
        log "starting (discovered): node $f"
        exec node "$f"
    fi
done

log "ERROR: could not find the API entry point. Set START_CMD above."
log "Contents of $(pwd):"
ls -la
if [ -f package.json ]; then
    log "package.json scripts:"
    sed -n '/"scripts"/,/}/p' package.json
fi
exit 1
