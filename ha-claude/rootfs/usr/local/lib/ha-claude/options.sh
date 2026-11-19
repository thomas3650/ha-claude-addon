# opt <jq-path> [default] - print an add-on option, or the default when the
# option is missing, empty, or the options file does not exist.
opt() {
  local value=""
  if [[ -f "$HC_OPTIONS" ]]; then
    value="$(jq -r "$1 // empty" "$HC_OPTIONS" 2>/dev/null || true)"
  fi
  printf '%s' "${value:-${2:-}}"
}

# opt_bool <jq-path> <default> - print true or false for a bool option, or
# the default when the option is missing, not a bool, or the options file
# does not exist. opt cannot do this: jq's // takes false for missing.
opt_bool() {
  local value=""
  if [[ -f "$HC_OPTIONS" ]]; then
    value="$(jq -r "$1 | if type == \"boolean\" then tostring else empty end" "$HC_OPTIONS" 2>/dev/null || true)"
  fi
  printf '%s' "${value:-$2}"
}

# opt_number <jq-path> <default> - print a whole number option, or the
# default when the option is missing or not a whole number.
opt_number() {
  local value
  value="$(opt "$1" "$2")"
  [[ "$value" =~ ^[0-9]+$ ]] || value="$2"
  printf '%s' "$value"
}
