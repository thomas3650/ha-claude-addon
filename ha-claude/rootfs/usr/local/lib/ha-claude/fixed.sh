# Fixed jobs: runs the house's automations once did, kept as one file each in
# the working folder's jobs/, named after the run's agent. The working folder
# is root's alone, so what is in it is trusted; the add-on knows nothing of
# what any of them does. The add-on places each file in the jobs folder as a
# job, so Home Assistant shows it, and checks the placed file against the
# working folder's before it is used: the placed file is in the Claude
# user's folder and may be anything by then.
#
# Like the jobs' own files, the placed ones are only ever read through a copy
# the Claude user makes (job_read) and only ever written by the Claude user:
# root never writes in the jobs folder.
: "${HC_FIXED_LOCK:=${HC_STATE:?}/fixed.lock}"

# _fixed_locked <command> [args...] - runs the command alone, as
# _mqtt_locked does, with a lock of its own: the placing and the switch's
# read-to-move of a file must not overlap, or a switch flipped between the
# two is lost.
_fixed_locked() {
  local lock="$HC_FIXED_LOCK" rc=0 tries=0
  mkdir -p "${lock%/*}"
  if command -v flock >/dev/null 2>&1; then
    {
      if ! flock -w 60 8; then
        log "fixed: the lock was not free"
        return 1
      fi
      "$@" || rc=$?
    } 8>"$lock"
    return "$rc"
  fi
  until mkdir "$lock.d" 2>/dev/null; do
    if (( ++tries > 600 )); then
      log "fixed: the lock was not free"
      return 1
    fi
    sleep 0.1
  done
  "$@" || rc=$?
  rmdir "$lock.d" 2>/dev/null
  return "$rc"
}

# fixed_is <name> - true when the working folder holds the name's file. A
# link is not a file: nobody but root writes there, but one is never followed.
fixed_is() {
  job_name_ok "$1" && [[ -f "$HC_WORKSPACE/jobs/$1.json" && ! -L "$HC_WORKSPACE/jobs/$1.json" ]]
}

# fixed_list - prints the fixed names, one per line, in order.
fixed_list() {
  local file name
  for file in "$HC_WORKSPACE"/jobs/*.json; do
    name="${file##*/}"; name="${name%.json}"
    fixed_is "$name" && printf '%s\n' "$name"
  done | sort
  return 0
}

# _fixed_normal <name> <file> - prints the file in its normal form, or fails
# and prints one word: shape, agent, run_by or schedule. It is the file's own
# check, for the placed file and the working folder's alike.
_fixed_normal() {
  local name="$1" file="$2" out members
  # jq keeps the last of a key written twice, so the members of the object
  # are counted from the parser's own events and set against the keys, as
  # job_check does.
  members="$(jq -n --stream '[inputs | select((length == 2 and (.[0] | length) == 1)
                                or (length == 1 and (.[0] | length) == 2))] | length' "$file" 2>/dev/null)" \
    || members=-1
  [[ "$members" =~ ^[0-9]+$ ]] || members=-1
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  if out="$(jq -cen --arg name "$name" --argjson members "$members" '
    def all_days: ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
    [inputs] | if length != 1 then error("shape") else .[0] end
    | if type != "object" or (keys | length) != $members then error("shape") else . end
    | if keys != ["agent", "enabled", "run_by", "schedule", "task"] then error("shape") else . end
    | if (.agent | type) != "string" or (.run_by | type) != "string" or (.enabled | type) != "boolean"
         or (.task | type) != "string" or (.task | length) == 0 or (.task | length) > 4000
         or (.schedule | type) != "object"
      then error("shape") else . end
    | if .agent != $name then error("agent") else . end
    | if .run_by != "automation" then error("run_by") else . end
    | .schedule |= (
        if (keys - ["days"]) != ["time"] then error("schedule")
        elif (.time | type) != "string" or (.time | test("^([01][0-9]|2[0-3]):[0-5][0-9]$") | not)
        then error("schedule")
        elif has("days") and ((.days | type) != "array" or (.days | length) == 0
              or (.days | unique | length) != (.days | length)
              or (.days - all_days) != [])
        then error("schedule")
        else {time, days: (if has("days") then [all_days[] as $d | select(.days | index($d)) | $d] else all_days end)}
        end)
    | {agent, run_by, schedule, task, enabled, end: null}
  ' "$file" 2>&1)"; then
    printf '%s\n' "$out"
    return 0
  fi
  out="${out##*$'\n'}"
  case "${out##*: }" in
    agent|run_by|schedule) echo "${out##*: }" ;;
    *) echo shape ;;
  esac
  return 1
}

# fixed_check <name> <copy> - checks a copy of the placed file against the
# working folder's: prints it in its normal form (agent, run_by, schedule
# with time and days, task, enabled and end, which is always null), or fails
# and prints one word: shape, agent, run_by, differs or schedule. Differs is
# every field but enabled not being the working folder's.
fixed_check() {
  local name="$1" copy="$2" out repo
  if ! fixed_is "$name"; then
    echo shape
    return 1
  fi
  out="$(_fixed_normal "$name" "$copy")" || { echo "$out"; return 1; }
  # The agent must exist as a file of its own: it is the run's instructions.
  if [[ ! -f "$HC_WORKSPACE/.claude/agents/$name.md" ]]; then
    echo agent
    return 1
  fi
  # The working folder's file is root's alone, so it is read as it is.
  repo="$(_fixed_normal "$name" "$HC_WORKSPACE/jobs/$name.json")" || { echo "$repo"; return 1; }
  if [[ "$(jq -cS 'del(.enabled)' <<<"$out")" != "$(jq -cS 'del(.enabled)' <<<"$repo")" ]]; then
    echo differs
    return 1
  fi
  printf '%s\n' "$out"
}

# _fixed_write <name> <file> - the Claude user writes the file as the
# listener writes a switched one: beside the placed file, then moved over it.
# What it writes comes on standard input, from a file of root's.
_fixed_write() {
  # shellcheck disable=SC2016  # the inner shell's arguments, not this one's
  as_claude sh -c 'cat > "$1.new" && mv -f "$1.new" "$1"' sh "$HC_JOBS/$1.json" < "$2" >/dev/null 2>&1
}

# _fixed_place_one <name> <previous-list-file> - places one name's file.
_fixed_place_one() {
  local name="$1" known="$2" copy new enabled=true word="" repo live=0
  repo="$HC_WORKSPACE/jobs/$name.json"
  copy="$(mktemp "$HC_STATE/job-fixed.XXXXXX")" || return 1
  new="$copy.new"
  # The working folder's file must be good before anything is placed from it.
  if ! word="$(_fixed_normal "$name" "$repo")"; then
    log "fixed: $name is not placed: the file in the working folder is refused ($word)"
    rm -f -- "$copy"
    return 0
  fi
  if [[ -e "$HC_JOBS/$name.json" || -L "$HC_JOBS/$name.json" ]]; then
    live=1
    if job_read "$name" "$copy"; then
      if word="$(fixed_check "$name" "$copy")"; then word=""; fi
      if [[ -z "$word" || "$word" == differs ]]; then
        # A fixed file: the switch's choice is kept.
        enabled="$(jq -r '.enabled' "$copy")"
      elif ! grep -qx -- "$name" "$known"; then
        # Not one the add-on placed: the chat's own file under a fixed name.
        word=chat
      fi
    else
      # A link, a pipe, a file too large or too slow: nothing of it is kept.
      word=unreadable
    fi
    if [[ "$word" == chat ]]; then
      if as_claude mkdir -p -- "$HC_JOBS/ended" </dev/null >/dev/null 2>&1 \
         && as_claude mv -f -- "$HC_JOBS/$name.json" "$HC_JOBS/ended/$name.json" </dev/null >/dev/null 2>&1; then
        log "fixed: $name was a job of the chat's; its file is moved to ended/ and the fixed job is placed"
      else
        log "fixed: $name is a job of the chat's, and its file could not be moved; it is not placed"
        rm -f -- "$copy"
        return 1
      fi
      live=0
    fi
  fi
  if ! ( umask 077; jq -c --argjson on "$enabled" '.enabled = $on' "$repo" > "$new" ) 2>/dev/null; then
    rm -f -- "$copy" "$new"
    return 1
  fi
  # Nothing is written when the placed file already is what would be.
  if (( live )) && [[ -f "$copy" && "$(jq -cS . "$copy" 2>/dev/null)" == "$(jq -cS . "$new")" ]]; then
    rm -f -- "$copy" "$new"
    return 0
  fi
  if _fixed_write "$name" "$new"; then
    log "fixed: $name is placed"
  else
    log "fixed: $name could not be placed"
    rm -f -- "$copy" "$new"
    return 1
  fi
  rm -f -- "$copy" "$new"
  jobs_on_change "$name"
}

# _fixed_place - the placing, under the lock.
_fixed_place() {
  local list="$HC_JOB_STATE/fixed.list" known name rc=0
  mkdir -p "$HC_JOB_STATE" "$HC_STATE"
  known="$(mktemp "$HC_STATE/job-fixed.XXXXXX")" || return 1
  [[ -f "$list" ]] && cat "$list" > "$known" 2>/dev/null
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    _fixed_place_one "$name" "$known" || rc=1
  done < <(fixed_list)
  # A name placed before whose file in the working folder has gone: its
  # placed file is deleted, not moved to ended/, as it holds nothing of the
  # chat's, and its state and entities go.
  while IFS= read -r name; do
    job_name_ok "$name" || continue
    fixed_is "$name" && continue
    as_claude rm -f -- "$HC_JOBS/$name.json" </dev/null >/dev/null 2>&1 || true
    log "fixed: $name is gone from the working folder; its job is removed"
    _job_forget "$name"
  done < "$known"
  ( umask 077; fixed_list > "$list.tmp" ) && mv -f "$list.tmp" "$list"
  rm -f -- "$known"
  return "$rc"
}

# fixed_place - puts every fixed file in the jobs folder, keeping the
# placed file's enabled while it is a valid fixed file, and removes the ones
# whose file has left the working folder. Run after each sync and at the
# start.
fixed_place() {
  _fixed_locked _fixed_place
}
