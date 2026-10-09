# opt <jq-path> [default] - print an add-on option, or the default when the
# option is missing, empty, or the options file does not exist.
opt() {
  local value=""
  if [[ -f "$HC_OPTIONS" ]]; then
    value="$(jq -r "$1 // empty" "$HC_OPTIONS" 2>/dev/null || true)"
  fi
  printf '%s' "${value:-${2:-}}"
}
