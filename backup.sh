#!/usr/bin/env bash
# Fetch the latest vaultwarden SQLite DB, attachments and sends from the remote host via SSH,
# pin the local compose.yml to the remote's vaultwarden version,
# and keep only the newest $KEEP backups.
set -euo pipefail
shopt -s inherit_errexit

BACKUP_DIR=backups
LOCAL_COMPOSE=compose.yml
LOCAL_DATA_DIR=data
LOCAL_CERT_DIR=certs
# Folders below /data that hold uploaded files referenced by the DB.
FILE_DIRS=(attachments sends)
# Matches the (optionally quoted) image value of an `image:` line referencing vaultwarden.
IMAGE_LINE_RE="^([[:space:]]*image:[[:space:]]*)[\"']?([^\"'[:space:]]*vaultwarden[^\"'[:space:]]*)[\"']?"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

load_config() {
  [[ -f .env ]] || die "Missing .env — copy .env.example and adjust it."
  # shellcheck disable=SC1091
  source .env
  : "${SSH_HOST:?SSH_HOST not set in .env}"
  : "${REMOTE_COMPOSE_PATH:?REMOTE_COMPOSE_PATH not set in .env}"
  REMOTE_SUDO="${REMOTE_SUDO:-}"
  KEEP="${KEEP:-5}"
  command -v docker >/dev/null || die "docker is required locally to run the backup."
}

# Run a POSIX sh script (stdin) on the remote host with the given arguments.
remote() {
  local args
  args=$(printf ' %q' "$@")
  ssh -o BatchMode=yes "$SSH_HOST" "$REMOTE_SUDO sh -s --$args"
}

# Print the value of `key=value` from the key/value lines in $2.
field() { sed -n "s/^$1=//p" <<<"$2"; }

# Print key=value lines (cid, image, version, data_dir) of the running remote container.
remote_info() {
  remote "$REMOTE_COMPOSE_PATH" <<'EOF'
set -eu
compose_file=$1
if docker compose version >/dev/null 2>&1; then dc="docker compose"; else dc="docker-compose"; fi
cid=""
for id in $($dc -f "$compose_file" ps -q); do
  img=$(docker inspect -f '{{.Config.Image}}' "$id")
  case $img in *vaultwarden*) cid=$id; break ;; esac
done
[ -n "$cid" ] || { echo "No running vaultwarden container found for $compose_file" >&2; exit 1; }
echo "cid=$cid"
echo "image=$img"
echo "version=$(docker exec "$cid" /vaultwarden --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
echo "data_dir=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$cid")"
EOF
}

# Stream a consistent DB snapshot of container $1 (host data dir $2) to stdout.
remote_snapshot() {
  remote "$1" "$2" <<'EOF'
set -eu
cid=$1
data_dir=$2
# Preferred: vaultwarden's built-in backup (>= 1.32), uses SQLite's online backup.
if out=$(docker exec "$cid" /vaultwarden backup 2>&1) && [ -n "$out" ]; then
  file=$(printf '%s\n' "$out" | sed -n "s/^Backup to '\(.*\)' was successful.*/\1/p")
  if [ -n "$file" ]; then
    docker exec "$cid" cat "$file"
    docker exec "$cid" rm -f "$file"
    exit 0
  fi
fi
# Fallback: sqlite3 on the host against the mounted data dir.
echo "vaultwarden backup command unavailable ($out), falling back to host sqlite3" >&2
command -v sqlite3 >/dev/null || { echo "sqlite3 not installed on remote host" >&2; exit 1; }
[ -n "$data_dir" ] || { echo "Could not determine host path of /data" >&2; exit 1; }
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
sqlite3 "$data_dir/db.sqlite3" ".backup '$tmp'"
cat "$tmp"
EOF
}

# Stream a tar of those of the folders $2... below /data of container $1 that exist
# (nothing if none do) to stdout.
remote_files() {
  remote "$@" <<'EOF'
set -eu
cid=$1
shift
existing=""
for d; do
  if docker exec "$cid" test -d "/data/$d"; then existing="$existing $d"; fi
done
[ -z "$existing" ] || docker exec "$cid" tar -C /data -cf - $existing
EOF
}

# Print image $1 pinned to a concrete version: a versioned tag is kept as-is,
# otherwise (latest, alpine, no tag, ...) the tag is replaced by version $2.
pin_image() {
  local image=${1%@*} running_version=$2 repo tag=""
  repo=$image
  if [[ ${image##*/} == *:* ]]; then
    tag=${image##*:}
    repo=${image%:*}
  fi
  if [[ $tag =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    echo "$repo:$tag"
    return
  fi
  [[ -n $running_version ]] || die "Could not determine running vaultwarden version."
  [[ $tag == *alpine* ]] && running_version+="-alpine"
  echo "$repo:$running_version"
}

# Print the semantic version contained in image tag $1.
image_version() { grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' <<<"${1##*:}" | head -n1; }

verify_sqlite() {
  # SQLite files start with this magic header.
  [[ $(head -c 16 "$1" | tr '\0' ' ') == "SQLite format 3 " ]] || die "Downloaded file is not a SQLite database."
  if command -v sqlite3 >/dev/null; then
    local result
    result=$(sqlite3 "$1" 'PRAGMA integrity_check;')
    [[ $result == ok ]] || die "Integrity check failed: $result"
  fi
}

# Download a snapshot of container $1 (data dir $2) as version $3; print its directory.
download_backup() {
  local stamp target tmp
  stamp=$(date +%Y%m%d_%H%M%S)
  target="$BACKUP_DIR/backup_${stamp}_$3"
  tmp="$BACKUP_DIR/.partial_$stamp"
  mkdir -p "$tmp"
  trap "rm -rf $(printf %q "$tmp")" EXIT
  log "Creating and downloading DB snapshot"
  remote_snapshot "$1" "$2" >"$tmp/db.sqlite3"
  verify_sqlite "$tmp/db.sqlite3"
  log "Downloading ${FILE_DIRS[*]}"
  remote_files "$1" "${FILE_DIRS[@]}" >"$tmp/files.tar"
  if [[ -s $tmp/files.tar ]]; then tar -xf "$tmp/files.tar" -C "$tmp"; fi
  rm "$tmp/files.tar"
  mv "$tmp" "$target"
  log "Saved $target ($(du -sh "$target" | cut -f1))"
  echo "$target"
}

update_local_compose() {
  local image=$1 current
  current=$(sed -nE "s#$IMAGE_LINE_RE.*#\2#p" "$LOCAL_COMPOSE" | head -n1)
  [[ -n $current ]] || die "No vaultwarden image line found in $LOCAL_COMPOSE"
  if [[ $current == "$image" ]]; then
    log "$LOCAL_COMPOSE already at $image"
    return
  fi
  sed -E "s#$IMAGE_LINE_RE#\1$image#" "$LOCAL_COMPOSE" >"$LOCAL_COMPOSE.tmp"
  cat "$LOCAL_COMPOSE.tmp" >"$LOCAL_COMPOSE" && rm "$LOCAL_COMPOSE.tmp"
  log "Updated $LOCAL_COMPOSE: $current -> $image"
}

local_compose() { docker compose -f "$LOCAL_COMPOSE" "$@" >&2; }

# The web vault only accepts https, so the local instance needs a certificate
# for localhost. mkcert's is trusted by the browser (after a one-time
# `mkcert -install`); the openssl fallback is self-signed.
ensure_local_cert() {
  local cert="$LOCAL_CERT_DIR/cert.pem" key="$LOCAL_CERT_DIR/key.pem"
  [[ -f $cert && -f $key ]] && return
  mkdir -p "$LOCAL_CERT_DIR"
  if command -v mkcert >/dev/null; then
    log "Creating localhost certificate with mkcert"
    mkcert -cert-file "$cert" -key-file "$key" localhost 127.0.0.1 >&2
  else
    log "Creating self-signed localhost certificate (install mkcert for a trusted one)"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=localhost \
      -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
      -keyout "$key" -out "$cert" 2>/dev/null
  fi
}

# Swap backup dir $1 in with the local instance stopped, then (re)start it; `up`
# also recreates the container when update_local_compose changed the image.
run_local_instance() {
  log "Stopping local vaultwarden"
  local_compose stop
  mkdir -p "$LOCAL_DATA_DIR"
  rm -f "$LOCAL_DATA_DIR/db.sqlite3-wal" "$LOCAL_DATA_DIR/db.sqlite3-shm"
  cp "$1/db.sqlite3" "$LOCAL_DATA_DIR/db.sqlite3"
  local d
  for d in "${FILE_DIRS[@]}"; do
    rm -rf "${LOCAL_DATA_DIR:?}/$d"
    if [[ -d $1/$d ]]; then cp -a "$1/$d" "$LOCAL_DATA_DIR/$d"; fi
  done
  log "Copied $1 to $LOCAL_DATA_DIR/"
  log "Starting local vaultwarden"
  local_compose up -d --wait
}

# Print the host port mapped to the container's port 80 in the local compose file.
local_port() {
  sed -nE 's/^[[:space:]]*-[[:space:]]*["'\'']?([0-9.]+:)?([0-9]+):80["'\'']?[[:space:]]*$/\2/p' "$LOCAL_COMPOSE" | head -n1
}

print_summary() {
  printf '\nBackup succeeded: %s\n' "$1"
  printf 'Local vaultwarden is running it at https://localhost:%s — log in with your usual account.\n' "$(local_port)"
}

# Keep the newest $KEEP backups. Names start with a timestamp, so lexical
# order == chronological order.
rotate_backups() {
  local backups old
  shopt -s nullglob
  backups=("$BACKUP_DIR"/backup_*/)
  ((${#backups[@]} > KEEP)) || return 0
  for old in "${backups[@]:0:${#backups[@]}-KEEP}"; do
    old=${old%/}
    rm -rf "$old"
    log "Deleted old backup $old"
  done
}

main() {
  cd "$(dirname "$(readlink -f "$0")")"
  load_config

  log "Inspecting vaultwarden on $SSH_HOST ($REMOTE_COMPOSE_PATH)"
  local info image backup
  info=$(remote_info)
  image=$(pin_image "$(field image "$info")" "$(field version "$info")")
  log "Remote runs $(field image "$info") (pinned: $image)"

  backup=$(download_backup "$(field cid "$info")" "$(field data_dir "$info")" "$(image_version "$image")")
  update_local_compose "$image"
  ensure_local_cert
  run_local_instance "$backup"
  rotate_backups
  print_summary "$backup"
}

main "$@"
