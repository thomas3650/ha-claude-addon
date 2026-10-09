# Shared set-up for the bats tests. Every test gets its own /data.
LIB="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/lib/ha-claude"

setup() {
  unset HC_OPTIONS HC_HOME HC_REPO HC_WORKSPACE HC_HANDOVER HC_STATE HC_STATUS HC_SESSION_NAME
  export HC_DATA="$BATS_TEST_TMPDIR/data"
  export HC_USER="$(id -un)"
  mkdir -p "$HC_DATA"
}

load_lib() {
  local name
  for name in paths log "$@"; do
    # shellcheck disable=SC1090
    source "$LIB/$name.sh"
  done
}

set_options() {
  printf '%s' "$1" > "$HC_DATA/options.json"
}
