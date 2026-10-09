log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2
}
