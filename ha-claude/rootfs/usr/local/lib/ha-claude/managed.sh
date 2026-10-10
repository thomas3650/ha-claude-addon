# Managed settings: a file .claude/managed-settings.json in the working
# folder becomes Claude Code's managed settings, which rank above every other
# settings file and which the Claude user cannot write. A file that is not
# exactly one JSON object never replaces a good one. The last good copy is
# kept under /data, because /etc is new after every image update.

# True when the file is a real file inside the working folder's own .claude
# folder. The copy below runs as root into a place the Claude user can read,
# so a link in the repo must not be able to point it at another file.
_managed_source_ok() {
  local src="$1" real_dir real_ws
  [[ -f "$src" && ! -L "$src" ]] || return 1
  real_dir="$(cd -P "$(dirname "$src")" 2>/dev/null && pwd -P)" || return 1
  real_ws="$(cd -P "$HC_WORKSPACE" 2>/dev/null && pwd -P)" || return 1
  [[ "$real_dir" == "$real_ws/.claude" ]] || return 1
  jq -es 'length == 1 and (.[0] | type == "object")' "$src" >/dev/null 2>&1
}

install_managed_settings() {
  local src="$HC_WORKSPACE/.claude/managed-settings.json"
  local keep="$HC_STATUS/managed-settings.json"
  local dst="$HC_MANAGED_DIR/managed-settings.json"
  mkdir -p "$HC_STATUS"
  if [[ ! -e "$src" && ! -L "$src" ]]; then
    if [[ -f "$keep" ]]; then
      rm -f "$keep"
      log "managed settings: none in the working folder; removed"
    fi
  elif _managed_source_ok "$src"; then
    if ! { cp "$src" "$keep.new" && mv "$keep.new" "$keep"; }; then
      log "managed settings: could not keep a copy; keeping the last good copy"
    fi
  else
    log "managed settings: the file in the working folder is not one JSON object in a real file; keeping the last good copy"
  fi
  if [[ -f "$keep" ]]; then
    mkdir -p "$HC_MANAGED_DIR"
    if ! { cp "$keep" "$dst.new" && chmod 644 "$dst.new" && mv "$dst.new" "$dst"; }; then
      log "managed settings: could not install the file"
    fi
  else
    rm -f "$dst"
  fi
  return 0
}
