# Workspace sync: fetch the repo set in repo_url into HC_REPO and publish
# only its assistant/ folder as HC_WORKSPACE. Never fatal: on any failure the
# previous workspace copy stays in place.

_sync_status() {
  mkdir -p "$HC_STATUS"
  printf '%s\n' "$1" > "$HC_STATUS/last_sync_status"
}

# Prints a private key given as text with its line breaks restored. A
# one-line field turns the line breaks into spaces or drops them, and may add
# carriage returns; the key is then not readable. The body of a key holds no
# white space of its own, so it is joined and folded again.
_key_text() {
  local raw="$1" body
  if [[ "$raw" =~ ^[[:space:]]*(-----BEGIN[A-Z\ ]+-----)(.*)(-----END[A-Z\ ]+-----)[[:space:]]*$ ]]; then
    body="${BASH_REMATCH[2]//[[:space:]]/}"
    printf '%s\n' "${BASH_REMATCH[1]}"
    while [[ -n "$body" ]]; do
      printf '%s\n' "${body:0:70}"
      body="${body:70}"
    done
    printf '%s\n' "${BASH_REMATCH[3]}"
  else
    printf '%s\n' "$raw"
  fi
}

# Writes the deploy key from the options to HC_STATE/deploy_key.
# Accepts the key as text or base64-encoded. Returns 1 if empty, 2 if invalid.
# A key with a passphrase counts as invalid: nobody is there to type it.
_write_deploy_key() {
  local raw key="$HC_STATE/deploy_key"
  raw="$(opt '.deploy_key')"
  rm -f "$key"
  [[ -n "$raw" ]] || return 1
  mkdir -p "$HC_STATE"
  ( umask 077
    if [[ "$raw" == *"BEGIN"* ]]; then
      _key_text "$raw" > "$key"
    else
      printf '%s' "$raw" | base64 -d > "$key" 2>/dev/null || true
    fi )
  if ! ssh-keygen -y -P '' -f "$key" </dev/null >/dev/null 2>&1; then
    rm -f "$key"
    return 2
  fi
}

# ssh never asks a question and gives up on a network that does not answer.
_git_ssh_command() {
  printf '%s' "ssh -i $HC_STATE/deploy_key -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HC_STATE/known_hosts"
}

_fetch_repo() {
  local url="$1"
  if [[ -d "$HC_REPO/.git" ]]; then
    git -C "$HC_REPO" remote set-url origin "$url" \
      && git -C "$HC_REPO" fetch --quiet --depth 1 origin HEAD \
      && git -C "$HC_REPO" reset --quiet --hard FETCH_HEAD
  else
    rm -rf "$HC_REPO"
    git clone --quiet --depth 1 "$url" "$HC_REPO"
  fi
}

_publish_workspace() {
  local src="$HC_REPO/assistant" new="$HC_WORKSPACE.new" old="$HC_WORKSPACE.old"
  [[ -d "$src" ]] || return 1
  rm -rf "$new" "$old"
  cp -R "$src" "$new"
  [[ -d "$HC_WORKSPACE" ]] && mv "$HC_WORKSPACE" "$old"
  mv "$new" "$HC_WORKSPACE"
  rm -rf "$old"
}

sync_workspace() {
  local url rc
  url="$(opt '.repo_url')"
  mkdir -p "$HC_WORKSPACE"
  if [[ -z "$url" ]]; then
    log "sync: no repo_url set; the workspace is left as it is"
    _sync_status none
    return 0
  fi
  if [[ "$url" != file://* ]]; then
    _write_deploy_key && rc=0 || rc=$?
    if (( rc == 1 )); then
      log "sync: the deploy key is empty; keeping the previous workspace"
      _sync_status "failed: deploy key is empty"
      return 0
    elif (( rc == 2 )); then
      log "sync: the deploy key is not a valid private key without a passphrase; keeping the previous workspace"
      _sync_status "failed: deploy key is not valid"
      return 0
    fi
    GIT_SSH_COMMAND="$(_git_ssh_command)"
    export GIT_SSH_COMMAND
  fi
  if ! _fetch_repo "$url" </dev/null 2>/dev/null; then
    log "sync: could not fetch the repo; keeping the previous workspace"
    _sync_status "failed: fetch"
    return 0
  fi
  if ! _publish_workspace; then
    log "sync: the repo has no assistant/ folder; keeping the previous workspace"
    _sync_status "failed: no assistant folder"
    return 0
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ > "$HC_STATUS/last_sync"
  _sync_status ok
  log "sync: workspace updated"
}
