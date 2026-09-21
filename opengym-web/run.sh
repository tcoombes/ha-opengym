#!/bin/sh
# ---------------------------------------------------------------------------
# openGym Web add-on entrypoint
#
# Does three jobs before starting the web server:
#
#   1. Repoints the reverse-proxy upstream. Upstream's config proxies /api to a
#      Docker Compose service called "api". On Home Assistant's network that
#      host doesn't exist - add-ons resolve each other as local-<slug> with
#      underscores turned into dashes, so opengym_api is local-opengym-api.
#
#   2. Moves the exercise images/GIFs onto the add-on's persistent /data volume
#      and symlinks them back into place, so the ~140 MB download survives an
#      add-on rebuild instead of being re-fetched every time.
#
#   3. Kicks off that download in the background on first run, so the UI comes
#      up immediately rather than Supervisor waiting on a 140 MB fetch.
# ---------------------------------------------------------------------------
set -e

OPTIONS=/data/options.json

log() { echo "[openGym Web] $*"; }

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

# Supervisor sets each add-on container's hostname to its add-on hostname:
# local-opengym-web for a local add-on, <repo-hash>-opengym-web for one from a
# repository. The API add-on from the same place is the same prefix with
# -opengym-api - so derive it rather than hardcoding a name that changes with
# where the add-ons were installed from. The api_host option still overrides.
API_HOST="$(opt api_host "")"
if [ -z "$API_HOST" ] || [ "$API_HOST" = "null" ]; then
    SELF="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null)"
    case "$SELF" in
        *-opengym-web)
            API_HOST="${SELF%-opengym-web}-opengym-api"
            log "api host: $API_HOST (derived from this add-on's hostname, $SELF)"
            ;;
        *)
            API_HOST=local-opengym-api
            log "WARNING: can't derive the API host from hostname '$SELF' -"
            log "falling back to $API_HOST. Set the api_host option to override."
            ;;
    esac
else
    log "api host: $API_HOST (from the api_host option)"
fi
API_PORT="$(opt api_port 3000)"
PERSIST_MEDIA="$(opt persist_media true)"
FETCH_MEDIA="$(opt fetch_media true)"

# --- 1. repoint the /api upstream -------------------------------------------
# Upstream's nginx resolves the API per-request through a `resolver` directive,
# so the hostname can appear in several shapes: a proxy_pass URL, a `set $var`
# line, an upstream block, or an envsubst template. We rewrite only the host
# token "api" in those positions - paths such as /api/ are never touched.
export API_HOST API_PORT

CONF_FILES=$(find /etc/nginx -type f \( -name '*.conf' -o -name '*.template' \) 2>/dev/null)

log "proxy config before rewrite:"
grep -nE 'resolver|proxy_pass|upstream[[:space:]]|set[[:space:]]+\$' $CONF_FILES 2>/dev/null | sed 's/^/    /' || true

for f in $CONF_FILES; do
    # set $var api;  /  set $var "api:3000";  /  server api:3000;
    sed -i -E \
        -e "s#(set[[:space:]]+\\\$[A-Za-z0-9_]+[[:space:]]+\"?(https?://)?)api([:;\"/[:space:]])#\1${API_HOST}\3#g" \
        -e "s#(server[[:space:]]+)api([:;[:space:]])#\1${API_HOST}\2#g" \
        "$f"
    # proxy_pass http://api...  - but if the file defines `upstream api { }`,
    # proxy_pass http://api; refers to that block by name, and rewriting it
    # would bypass the block and silently drop its port. Leave it alone there.
    if ! grep -qE 'upstream[[:space:]]+api[[:space:]]*\{' "$f"; then
        sed -i -E "s#(https?://)api([^A-Za-z0-9_.-]|\$)#\1${API_HOST}\2#g" "$f"
    fi
done

if grep -q "$API_HOST" $CONF_FILES 2>/dev/null; then
    log "proxy config after rewrite:"
    grep -nE 'resolver|proxy_pass|upstream[[:space:]]|set[[:space:]]+\$' $CONF_FILES 2>/dev/null | sed 's/^/    /' || true
else
    log "no literal 'api' host in the config - relying on the env override below"
fi

# Upstream's template builds the upstream as http://${BACKEND}:${PORT}, and the
# nginx image's 20-envsubst-on-templates.sh fills those in AFTER this script
# runs - so the fix is to override the variables, not the text. BACKEND is set
# explicitly; the loop catches any other variable the image sets to plain "api".
export BACKEND="$API_HOST"
log "env BACKEND -> $BACKEND"
for kv in $(env | grep -E '^[A-Za-z_][A-Za-z0-9_]*=api$'); do
    _name="${kv%%=*}"
    export "$_name=$API_HOST"
    log "env $_name: api -> $API_HOST"
done
if [ "${PORT:-}" != "$API_PORT" ]; then
    log "env PORT: ${PORT:-unset} -> $API_PORT"
    export PORT="$API_PORT"
fi

# nginx's runtime resolver ignores /etc/hosts and only asks the DNS server
# named in its `resolver` directive. Find a nameserver that actually knows the
# API add-on's name and point any resolver directive at it.
RESOLVER=""
for ns in 127.0.0.11 $(awk '/^nameserver/ { print $2 }' /etc/resolv.conf 2>/dev/null); do
    if nslookup "$API_HOST" "$ns" >/dev/null 2>&1; then
        RESOLVER="$ns"
        break
    fi
done

if [ -n "$RESOLVER" ]; then
    log "$API_HOST resolves via $RESOLVER"
    export RESOLVER
    for f in $CONF_FILES; do
        sed -i -E "s#^([[:space:]]*resolver[[:space:]]+)[^;]+;#\1${RESOLVER} valid=10s ipv6=off;#" "$f"
    done
else
    log "WARNING: $API_HOST does not resolve - is the openGym API add-on running?"
fi

# --- 2. exercise media ------------------------------------------------------
# Upstream's one-shot `media` compose service is just:
#   git clone --depth 1 https://github.com/hasaneyldrm/exercises-dataset
#   cp images/*.jpg -> img/   and   videos/*.gif -> gif/
# and web serves them from /usr/share/nginx/html/{img,gif}. We do the same job
# here, into the add-on's persistent /data so it downloads once, then symlink
# those two paths to it. git is added to the image in our Dockerfile.
#
# Images and GIFs are (c) Gym visual, used under the exercises-dataset terms -
# openGym doesn't redistribute them, and neither does this add-on.
HTML_ROOT=/usr/share/nginx/html
DATASET=https://github.com/hasaneyldrm/exercises-dataset

if [ "$PERSIST_MEDIA" = "true" ]; then
    MEDIA_DIR=/data/media
else
    MEDIA_DIR="$HTML_ROOT"
fi
mkdir -p "$MEDIA_DIR/img" "$MEDIA_DIR/gif"

if [ "$MEDIA_DIR" != "$HTML_ROOT" ]; then
    for sub in img gif; do
        [ -L "$HTML_ROOT/$sub" ] || rm -rf "$HTML_ROOT/$sub"
        ln -sfn "$MEDIA_DIR/$sub" "$HTML_ROOT/$sub"
    done
    # nginx workers run as the unprivileged `nginx` user, so every directory on
    # the way down to the files must be traversable, or images come back 403.
    chmod a+rx /data "$MEDIA_DIR" "$MEDIA_DIR/img" "$MEDIA_DIR/gif" 2>/dev/null || true
    log "img/ and gif/ -> $MEDIA_DIR (persistent, excluded from HA backups)"
fi

fetch_media() {
    _tmp="$(mktemp -d)"
    log "downloading exercise media (~140 MB, one time) from $DATASET"
    if git clone --depth 1 --quiet "$DATASET" "$_tmp/ds" \
        && cp "$_tmp"/ds/images/*.jpg "$MEDIA_DIR/img/" \
        && cp "$_tmp"/ds/videos/*.gif "$MEDIA_DIR/gif/"; then
        chmod -R a+rX "$MEDIA_DIR/img" "$MEDIA_DIR/gif"
        touch "$MEDIA_DIR/.complete"
        log "exercise media ready: $(ls "$MEDIA_DIR/img" | wc -l) images, $(ls "$MEDIA_DIR/gif" | wc -l) GIFs"
    else
        log "media download FAILED - it will retry on the next add-on start"
    fi
    rm -rf "$_tmp"
}

# A marker file rather than upstream's "is img/ empty?" check, so a download
# that dies halfway through retries on the next start instead of being
# mistaken for a finished one.
if [ -f "$MEDIA_DIR/.complete" ]; then
    log "exercise media already present ($(ls "$MEDIA_DIR/img" | wc -l) images)"
elif [ "$FETCH_MEDIA" != "true" ]; then
    log "fetch_media is off - exercise images will be missing"
elif ! command -v git >/dev/null 2>&1; then
    log "ERROR: git not found - rebuild the add-on so the Dockerfile adds it"
else
    # Background it so nginx comes up immediately; images appear when it's done.
    fetch_media &
fi

# --- start the web server ---------------------------------------------------
if [ "$#" -gt 0 ]; then
    log "starting: $*"
    exec "$@"
fi

if [ -x /docker-entrypoint.sh ]; then
    log "starting via /docker-entrypoint.sh"
    exec /docker-entrypoint.sh nginx -g 'daemon off;'
fi

if command -v nginx >/dev/null 2>&1; then
    log "starting nginx"
    exec nginx -g 'daemon off;'
fi

log "ERROR: could not work out how to start the web server."
log "Check the upstream web/Dockerfile and hardcode the command here."
exit 1
