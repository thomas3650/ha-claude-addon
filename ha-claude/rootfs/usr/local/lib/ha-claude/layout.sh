# Folders under /data and who owns them:
#   workspace  root, read-only for the Claude user
#   handover   Claude user
#   home       Claude user
#   status     root, readable by the Claude user
#   state, repo, options file   root only
ensure_layout() {
  mkdir -p "$HC_HOME" "$HC_HANDOVER" "$HC_STATE" "$HC_STATUS" "$HC_WORKSPACE"
  [[ "$(id -u)" == 0 ]] || return 0
  chown -R "$HC_USER:$HC_USER" "$HC_HOME" "$HC_HANDOVER"
  chown -R root:root "$(dirname "$HC_WORKSPACE")" "$HC_STATE" "$HC_STATUS"
  chmod -R u=rwX,go=rX "$(dirname "$HC_WORKSPACE")" "$HC_STATUS"
  chmod 700 "$HC_STATE"
  if [[ -d "$HC_REPO" ]]; then
    chown -R root:root "$HC_REPO"
    chmod 700 "$HC_REPO"
  fi
  [[ -f "$HC_OPTIONS" ]] && chmod 600 "$HC_OPTIONS"
  return 0
}
