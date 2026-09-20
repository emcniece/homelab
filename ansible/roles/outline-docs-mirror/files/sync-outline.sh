#!/bin/sh
# Managed by https://github.com/emcniece/homelab
#
# Exports every Outline collection to markdown and syncs it into a local
# git repo under /data, on a plain sleep-loop schedule. git gives us a
# cheap history/diff of what changed between syncs without needing a
# separate versioning mechanism.
#
# Outline API calls used (verify against the running instance's version —
# these are the documented collections.export_all / fileOperations.*
# endpoints as of Outline's current API, but confirm on first run):
#   POST /api/collections.export_all  -> { data: { fileOperation: { id } } }
#   POST /api/fileOperations.info     -> { data: { state } }  (poll until "complete")
#   POST /api/fileOperations.redirect -> 302 to the export zip
set -eu

: "${OUTLINE_URL:?OUTLINE_URL is required}"
: "${OUTLINE_API_TOKEN:?OUTLINE_API_TOKEN is required}"
: "${SYNC_INTERVAL:=6h}"

DATA_DIR=/data
EXPORT_DIR="$DATA_DIR/docs"
WORK_DIR=/tmp/outline-export

log() {
    echo "[$(date -Iseconds)] $*"
}

api_post() {
    # $1 = path, $2 = JSON body
    curl -sf -X POST "$OUTLINE_URL$1" \
        -H "Authorization: Bearer $OUTLINE_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$2"
}

sync_once() {
    log "starting export"

    op_id=$(api_post /api/collections.export_all '{"format":"outline-markdown"}' \
        | jq -r '.data.fileOperation.id // empty')

    if [ -z "$op_id" ]; then
        log "ERROR: export request did not return a fileOperation id"
        return 1
    fi

    state=""
    i=0
    while [ "$i" -lt 60 ]; do
        state=$(api_post /api/fileOperations.info "{\"id\":\"$op_id\"}" \
            | jq -r '.data.state // empty')
        [ "$state" = "complete" ] && break
        if [ "$state" = "error" ]; then
            log "ERROR: export failed server-side (fileOperation $op_id)"
            return 1
        fi
        i=$((i + 1))
        sleep 10
    done

    if [ "$state" != "complete" ]; then
        log "ERROR: export timed out waiting on fileOperation $op_id"
        return 1
    fi

    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR/extracted"

    # fileOperations.redirect 302s to a presigned B2/S3 URL. Don't use
    # curl -L here: it would forward our Outline Authorization header to
    # that URL too, which B2 rejects (presigned auth is in the query
    # string, not a header) — confirmed empirically, this silently curl
    # -f's out and leaves the zip empty. Extract the redirect target and
    # fetch it as a clean, unauthenticated request instead.
    download_url=$(curl -sf -X POST "$OUTLINE_URL/api/fileOperations.redirect" \
        -H "Authorization: Bearer $OUTLINE_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"$op_id\"}" \
        -o /dev/null -w '%{redirect_url}')

    if [ -z "$download_url" ]; then
        log "ERROR: fileOperations.redirect did not return a redirect URL"
        return 1
    fi

    curl -sf "$download_url" -o "$WORK_DIR/export.zip"

    unzip -q -o "$WORK_DIR/export.zip" -d "$WORK_DIR/extracted"

    mkdir -p "$EXPORT_DIR"
    rsync -a --delete "$WORK_DIR/extracted/" "$EXPORT_DIR/"
    rm -rf "$WORK_DIR"

    cd "$EXPORT_DIR"
    [ -d .git ] || git init -q
    git config user.email "outline-docs-mirror@localhost"
    git config user.name "outline-docs-mirror"
    git add -A

    if git diff --cached --quiet; then
        log "synced, no changes"
    else
        git commit -q -m "sync $(date -Iseconds)"
        log "synced, committed changes"
    fi
}

interval_seconds() {
    case "$SYNC_INTERVAL" in
        *h) echo $(( ${SYNC_INTERVAL%h} * 3600 )) ;;
        *m) echo $(( ${SYNC_INTERVAL%m} * 60 )) ;;
        *s) echo $(( ${SYNC_INTERVAL%s} )) ;;
        *) log "unrecognized SYNC_INTERVAL '$SYNC_INTERVAL', defaulting to 6h"; echo 21600 ;;
    esac
}

while true; do
    sync_once || log "sync failed, will retry next interval"
    sleep "$(interval_seconds)"
done
