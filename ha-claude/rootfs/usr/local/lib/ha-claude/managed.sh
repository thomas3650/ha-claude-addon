# Managed settings: a file .claude/managed-settings.json in the working
# folder becomes Claude Code's managed settings, which rank above every other
# settings file and which the Claude user cannot write. A file that is not a
# JSON object never replaces a good one. The last good copy is kept under
# /data, because /etc is new after every image update.
install_managed_settings() {
  local src="$HC_WORKSPACE/.claude/managed-settings.json"
  local keep="$HC_STATUS/managed-settings.json"
  local dst="$HC_MANAGED_DIR/managed-settings.json"
  mkdir -p "$HC_STATUS"
  if [[ ! -f "$src" ]]; then
    if [[ -f "$keep" ]]; then
      rm -f "$keep"
      log "managed settings: none in the working folder; removed"
    fi
  elif jq -e 'type == "object"' "$src" >/dev/null 2>&1; then
    cp "$src" "$keep.new" && mv "$keep.new" "$keep"
  else
    log "managed settings: the file in the working folder is not a JSON object; keeping the last good copy"
  fi
  if [[ -f "$keep" ]]; then
    mkdir -p "$HC_MANAGED_DIR"
    cp "$keep" "$dst.new" && chmod 644 "$dst.new" && mv "$dst.new" "$dst"
  else
    rm -f "$dst"
  fi
  return 0
}
