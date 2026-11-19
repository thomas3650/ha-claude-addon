# Folders under /data and who owns them:
#   workspace  root, read-only for the Claude user
#   handover   Claude user
#   results    Claude user, and its jobs folder
#   jobs       Claude user (the job files the chat writes), and its .requests
#              (the chat's requests to run a job now, jobs_requests)
#   home       Claude user
#   status     root, readable by the Claude user; its jobs/ holds each job's
#              public copy of its state, for the chat's job_status
#   state, repo, options file   root only (state holds the jobs' own state)
ensure_layout() {
  mkdir -p "$HC_HOME" "$HC_HANDOVER" "$HC_RESULTS" "$HC_STATE" "$HC_STATUS" "$HC_WORKSPACE" \
           "$HC_JOBS" "$HC_JOB_STATE"
  if [[ "$(id -u)" != 0 ]]; then
    mkdir -p "$HC_JOB_RESULTS" "$HC_JOBS/ended" "$HC_JOB_REQUESTS"
    return 0
  fi
  chown -R "$HC_USER:$HC_USER" "$HC_HOME" "$HC_HANDOVER"
  # The folder only: what is in it is the Claude user's already, and a
  # recursive change would follow whatever that user put there.
  chown "$HC_USER:$HC_USER" "$HC_RESULTS" "$HC_JOBS"
  # Inside folders that are the Claude user's: made by that user, so a link
  # put there is never followed by root.
  runuser -u "$HC_USER" -- mkdir -p "$HC_JOB_RESULTS" "$HC_JOBS/ended" "$HC_JOB_REQUESTS" </dev/null 2>/dev/null || true
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
