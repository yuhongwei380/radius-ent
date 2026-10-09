#!/bin/sh
set -eu

LOG_FILE="${HC_LOG_FILE:-/var/log/freeradius/radius.log}"
PATTERN="${HC_TIMEOUT_PATTERN:-users failed: 500 read timeout}"
MAX_HITS="${HC_TIMEOUT_MAX_HITS:-3}"
STATE_FILE="${HC_STATE_FILE:-/tmp/radius-timeout-health.state}"

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

pick_log_file() {
  if [ -f "$LOG_FILE" ]; then
    printf '%s\n' "$LOG_FILE"
    return 0
  fi

  alt_file="$(find /var/log/freeradius -maxdepth 1 -type f -name '*.log' 2>/dev/null | head -n 1 || true)"
  if [ -n "$alt_file" ] && [ -f "$alt_file" ]; then
    printf '%s\n' "$alt_file"
    return 0
  fi

  return 1
}

if ! log_path="$(pick_log_file)"; then
  echo "healthcheck: no radius log file found under /var/log/freeradius" >&2
  exit 0
fi

if [ ! -f "$STATE_FILE" ]; then
  initial_total="$(wc -l < "$log_path" 2>/dev/null || echo 0)"
  if ! is_uint "$initial_total"; then
    initial_total=0
  fi
  {
    printf 'offset=%s\n' "$initial_total"
    printf 'hits=0\n'
  } > "$STATE_FILE"
  exit 0
fi

offset="$(sed -n 's/^offset=//p' "$STATE_FILE" | head -n 1)"
hits="$(sed -n 's/^hits=//p' "$STATE_FILE" | head -n 1)"

if ! is_uint "$offset"; then
  offset=0
fi
if ! is_uint "$hits"; then
  hits=0
fi

total="$(wc -l < "$log_path" 2>/dev/null || echo 0)"
if ! is_uint "$total"; then
  total=0
fi

# Log rotated/truncated: reset offset and count.
if [ "$total" -lt "$offset" ]; then
  offset=0
  hits=0
fi

new_hits=0
if [ "$total" -gt "$offset" ]; then
  start_line=$((offset + 1))
  new_hits="$(sed -n "${start_line},${total}p" "$log_path" | grep -F -c "$PATTERN" || true)"
fi

if ! is_uint "$new_hits"; then
  new_hits=0
fi

if [ "$new_hits" -gt 0 ]; then
  hits=$((hits + new_hits))
else
  hits=0
fi

{
  printf 'offset=%s\n' "$total"
  printf 'hits=%s\n' "$hits"
} > "$STATE_FILE"

if [ "$hits" -ge "$MAX_HITS" ]; then
  echo "healthcheck: timeout pattern detected ${hits} time(s), marking unhealthy" >&2
  exit 1
fi

exit 0
