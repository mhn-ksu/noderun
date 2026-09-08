#!/usr/bin/env bash
#
# noderun.sh - replacement for `knife ssh` where bundled
# net-ssh gem can't negotiate modern ciphers
#
# Uses `knife search node` to build a list of FQDNs,
# then runs commands againt them with the SYSTEM ssh binary
# instead  of Chef's embedded net-ssh.
#
# Usage:
#   noderun.ssh -q <QUERY> -c <COMMAND> [options]
#
# Required:
#   -q QUERY      knife serach query, e.g., 'role:web AND chef_environment:prod'
#   -c COMMAND    Command (or ; / && chain) to run on each node
#
# Options:
#   -a ATTRIBUTE  Node attributes to use as hostname (default: fqdn)
#   -u USER       SSH use (default: current user)
#   -i IDENTITY   Path to SSH private ksy
#   -p PARALLEL   Max concurent SSH sessions (default: 10)
#   -o SSH_OPTS   Extra raw options pass to ssh, e.g., -o "-p 2222"
#   -n            Dry run: print the node list from knife search and exit
#   -y            Skip the confirmation prompt
#   -h            Show this help message
#
# Examples:
#   noderun.sh -q "role:webserver AND chef_environment:prod" -c "uptime"
#   noderun.sh -q "tags:needs_patch" -c "sudo yum update -y" -p 10 -u chefadmin
#   noderun.sh -q "recipe:apache24" -a fqdn -n
#
set -euo pipefail

ATTRIBUTE="fqdn"
PARALLEL=10
TIMEOUT=10
SSH_USER=""
IDENTITY=""
EXTRA_SSH_OPTS=""
DRY_RUN=0
ASSUME_YES=0
QUERY=""
COMMAND=""

usage() {
  sed -n '2,29p' "$0" | sed 's/^# \{0,1}//'
  exit "${1:-1}"
}

while getopts ":q:c:a:u:i:p:t:o:nyh" opt; do
  case "$opt" in
    q) QUERY="$OPTARG" ;;
    c) COMMAND="$OPTARG" ;;
    a) ATTRIBUTE="$OPTARG" ;;
    u) SSH_USER="$OPTARG" ;;
    i) IDENTITY="$OPTARG" ;;
    p) PARALLEL="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    o) EXTRA_SSH_OPTS="$OPTARG" ;;
    n) DRY_RUN=1 ;;
    y) ASSUME_YES=1 ;;
    h) usage 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage ;;
    :) echo "Option -$OPTARG requires an argument" >&2; usage ;;
  esac
done

if [[ -z "$QUERY" ]]; then
  echo "Error: -q QUERY is required" >&2
  usage
fi
if [[ "$DRY_RUN" -eq 0 && -z "$COMMAND" ]]; then
  echo "Error: -c COMMAND is required (unless using -n for a dry run)" >&2
  usage
fi

for bin in knife jq ssh; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Error: '$bin' not found in PATH" >&2; exit 1; }
done

echo "Querying Chef server: knife serach node \"$QUERY\" -a $ATTRIBUTE" >&2

SEARCH_JSON="$(knife search node "$QUERY" -a "$ATTRIBUTE" -F json 2>/tmp/noderun.knife.err)" || {
  echo "Error: knife search failed:" >&2
  cat /tmp/noderun.knife.err >&2
  exit 1
}

mapfile -t HOSTS < <(echo "$SEARCH_JSON" | jq -r --arg attr "$ATTRIBUTE" '
  .rows[]
  | to_entries[]
  | .value
  | (
      .[$attr]
      // (.data[$attr]?)
      // (.automatic[$attr]?)
      // (.normal[$attr]?)
      // (.default[$attr]?)
      // (.override[$attr]?)
      // empty
    )
  | select(. != null and . != "")
' | sort -u)

if [[ "${#HOSTS[@]}" -eq 0 ]]; then
  echo "No nodes matched query, or none have a '$ATTRIBUTE' attribute set." >&2
  echo "Raw knife JSON for debugging (first row):" >&2
  echo "$SEARCH_JSON" | jq '.rows[0] // "no rows returned"' >&2
  exit 1
fi

echo ""
echo "Matched ${#HOSTS[@]} node(s):"
printf '  %s\n' "${HOSTS[@]}"
echo ""

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: exiting before executing command"
  exit 0
fi

echo "Command to run on each node:"
echo "  $COMMAND"
echo ""

if [[ "$ASSUME_YES" -eq 0 ]]; then
  read -r -p "Proceed? [y/N] " CONFIRM
  case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

SSH_BASE_OPTS=(-o BatchMode=yes -o ConnectTimeout="$TIMEOUT" -o StrictHostKeyChecking=accept-new)
[[ -n "$IDENTITY" ]] && SSH_BASE_OPTS+=(-i "$IDENTITY")
if [[ -n "$EXTRA_SSH_OPTS" ]]; then
  # shellcheck disable=SC2206
  SSH_BASE_OPTS+=($EXTRA_SSH_OPTS)
fi

RESULT_DIR="$(mktemp -d)"
trap 'rm -rf "$RESULT_DIR"' EXIT

SSH_BASE_OPTS_STR="${SSH_BASE_OPTS[*]}"
export SSH_USER COMMAND SSH_BASE_OPTS_STR RESULT_DIR

run_one() {
  local host="$1"
  local target="$host"
  [[ -n "$SSH_USER" ]] && target="${SSH_USER}@${host}"

  # shellcheck disable=SC2206
  local ssh_opts=($SSH_BASE_OPTS_STR)

  local out
  local rc
  if out=$(ssh "${ssh_opts[@]}" "$target" -- "$COMMAND" 2>&1); then
    rc=0
  else
    rc=$?
  fi

  # Prefix every out line with the hostname, like knife ssh did.
  if [[ -n "$out" ]]; then
    while IFS= read -r line; do
      printf '%-40s | %s\n' "$host" "$line"
    done <<< "$out"
  fi

  if [[ "$rc" -ne 0 ]]; then
    printf '%-40s | [EXIT CODE %s]\n' "$host" "$rc" >&2
  fi

  # Record per-host result so parent can tally success/failure
  # even when hosts ran in parallel shells
  echo "$rc" > "$RESULT_DIR/$host.rc"

  # NOTE: always return 0 here, even on failure. GNU xargs treats an
  # exit status of 255 from any invocation as a signal to abort the
  # entire run immediately, and ssh uses 255 for connection-level
  # failures (unreachable host, DNS failure, auth failure, etc).
  # Without this, one unreachable node would silently kill the batch
  # for every remaining host. The real per-host exit code is already
  # recorded above and is what the final tally reads.
  return 0
}
export -f run_one

TOTAL="${#HOSTS[@]}"

set +e
if [[ "$PARALLEL" -le 1 ]]; then
  for host in "${HOSTS[@]}"; do
    run_one "$host"
  done
else
  printf '%s\n' "${HOSTS[@]}" | xargs -I{} -P "$PARALLEL" bash -c 'run_one "$@"' _ {}
fi
set -e

FAIL_COUNT=0
for f in "$RESULT_DIR"/*.rc; do
  [[ -e "$f" ]] || continue
  rc="$(cat "$f")"
  [[ "$rc" -ne 0 ]] && FAIL_COUNT=$((FAIL_COUNT + 1))
done

echo ""
echo "Done. $TOTAL node(s) targets. $((TOTAL - FAIL_COUNT)) succeeded, $FAIL_COUNT failed."
