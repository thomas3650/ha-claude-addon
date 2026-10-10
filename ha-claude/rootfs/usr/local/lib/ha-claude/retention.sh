# Prints the date N days before today as YYYY-MM-DD. GNU date first, then BSD.
_days_ago() {
  date -d "$1 days ago" +%F 2>/dev/null || date -v-"$1"d +%F
}

# Handover files are kept for HC_HANDOVER_DAYS days (default 30). A file is
# judged by the date in its name, not by when it was last changed, and only
# plain files named YYYY-MM-DD.md are ever removed.
prune_handover() {
  local cutoff file name day removed=0 days="${HC_HANDOVER_DAYS:-30}"
  [[ "$days" =~ ^[0-9]+$ ]] || return 0
  cutoff="$(_days_ago "$days")" || return 0
  for file in "$HC_HANDOVER"/*.md; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    name="${file##*/}"; day="${name%.md}"
    [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    if [[ "$day" < "$cutoff" ]]; then
      rm -f "$file" && removed=$((removed + 1))
    fi
  done
  if (( removed )); then
    log "handover: removed $removed file(s) older than $days days"
  fi
  return 0
}

# The handover folder is the one place Claude can write. Nothing that Claude
# Code would read as instructions or settings belongs there, so such files
# are removed before Claude Code starts. Names are matched without regard to
# case. The removal is done as the Claude user, who owns the folder: done as
# root, a folder swapped for a link at the right moment could point the
# removal at a file outside it.
clean_handover() {
  local removed=0
  local -a runner=()
  [[ -d "$HC_HANDOVER" ]] || return 0
  if [[ "$(id -u)" == 0 ]] && declare -F as_claude >/dev/null; then
    runner=(as_claude)
  fi
  removed="$("${runner[@]}" find "$HC_HANDOVER" -mindepth 1 \( -iname CLAUDE.md -o -iname CLAUDE.local.md \
               -o -iname .claude -o -iname .mcp.json \) -prune -print -exec rm -rf {} + 2>/dev/null | wc -l)"
  removed="${removed//[[:space:]]/}"
  if (( ${removed:-0} )); then
    log "handover: removed $removed file(s) that could be read as instructions"
  fi
  return 0
}
