#!/usr/bin/env bash
#
# noderun.sh - replacement for `knife ssh` where bundled
# net-ssh gem can't negotiate modern ciphers
#
# Uses `knife search node` to build a list of FQDNs,
# then runs commands against them with the SYSTEM ssh binary
# instead of Chef's embedded net-ssh.
#
# Each host is tried with key-based auth first. If a password is
# supplied (-w, -W, or NODERUN_SSH_PASS) and a host rejects the key
# ("Permission denied"), that host is retried with the password via
# sshpass.
#
# By default only the command's own output is shown inline. SSH
# connection errors (DNS, timeouts, auth failures), login banners and
# exit codes are collected into a summary at the end. Use -v to show
# them inline as well.
#
# Usage:
#   noderun.sh -q <QUERY> -c <COMMAND> [options]
#
# Required:
#   -q QUERY      knife search query, e.g., 'role:web AND chef_environment:prod'
#   -c COMMAND    Command (or ; / && chain) to run on each node
#
# Options:
#   -a ATTRIBUTE  Node attribute to use as hostname (default: fqdn)
#   -u USER       SSH user (default: current user)
#   -i IDENTITY   Path to SSH private key
#   -p PARALLEL   Max concurrent SSH sessions (default: 10)
#   -t TIMEOUT    SSH connect timeout in seconds (default: 10)
#   -o SSH_OPTS   Extra raw options passed to ssh, e.g., -o "-p 2222"
#   -W            Prompt (hidden input) for an SSH password to fall back on
#   -w PASSWORD   SSH password to fall back on (visible in ps/shell history;
#                 prefer -W or the NODERUN_SSH_PASS environment variable)
#   -v            Verbose: show ssh messages, banners and exit codes inline
#   -n            Dry run: print the node list from knife search and exit
#   -y            Skip the confirmation prompt
#   -h            Show this help message
#
# Environment:
#   NODERUN_SSH_PASS  Fallback SSH password (used if -w/-W not given)
#
# Examples:
#   noderun.sh -q "role:webserver AND chef_environment:prod" -c "uptime"
#   noderun.sh -q "tags:needs_patch" -c "sudo yum update -y" -p 10 -u chefadmin
#   noderun.sh -q "role:legacy" -c "uptime" -u chefadmin -W
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
SSH_PASSWORD="${NODERUN_SSH_PASS:-}"
PROMPT_PASSWORD=0
VERBOSE=0

usage() {
  # Print the leading comment block (minus the shebang) as help text
  awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
  exit "${1:-1}"
}

while getopts ":q:c:a:u:i:p:t:o:w:Wvnyh" opt; do
  case "$opt" in
    q) QUERY="$OPTARG" ;;
    c) COMMAND="$OPTARG" ;;
    a) ATTRIBUTE="$OPTARG" ;;
    u) SSH_USER="$OPTARG" ;;
    i) IDENTITY="$OPTARG" ;;
    p) PARALLEL="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    o) EXTRA_SSH_OPTS="$OPTARG" ;;
    w) SSH_PASSWORD="$OPTARG" ;;
    W) PROMPT_PASSWORD=1 ;;
    v) VERBOSE=1 ;;
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

# sshpass is only needed if a password may be used
if [[ "$DRY_RUN" -eq 0 && ( "$PROMPT_PASSWORD" -eq 1 || -n "$SSH_PASSWORD" ) ]]; then
  command -v sshpass >/dev/null 2>&1 || {
    echo "Error: password fallback requested but 'sshpass' not found in PATH" >&2
    echo "       (install it, e.g. 'sudo yum install sshpass' or 'sudo apt install sshpass')" >&2
    exit 1
  }
fi

echo "Querying Chef server: knife search node \"$QUERY\" -a $ATTRIBUTE" >&2

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

if [[ "$PROMPT_PASSWORD" -eq 1 ]]; then
  read -r -s -p "SSH password (fallback if key auth fails): " SSH_PASSWORD
  echo ""
  if [[ -z "$SSH_PASSWORD" ]]; then
    echo "Warning: empty password entered; password fallback disabled." >&2
  fi
fi

# Key-auth options: BatchMode keeps ssh from ever prompting
SSH_BASE_OPTS=(-o BatchMode=yes -o ConnectTimeout="$TIMEOUT" -o StrictHostKeyChecking=accept-new)
[[ -n "$IDENTITY" ]] && SSH_BASE_OPTS+=(-i "$IDENTITY")

# Password-auth options: separate array because ssh uses the FIRST value
# it sees for an option, so BatchMode=yes can't be overridden later
SSH_PW_OPTS=(-o BatchMode=no -o ConnectTimeout="$TIMEOUT" -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1)

if [[ -n "$EXTRA_SSH_OPTS" ]]; then
  # shellcheck disable=SC2206
  SSH_BASE_OPTS+=($EXTRA_SSH_OPTS)
  # shellcheck disable=SC2206
  SSH_PW_OPTS+=($EXTRA_SSH_OPTS)
fi

# Quiet mode: LogLevel=ERROR hides login banners and warnings such as
# "Permanently added ... to the list of known hosts". Added after the
# -o extras so a LogLevel passed there takes precedence (ssh keeps the
# first value it sees).
if [[ "$VERBOSE" -eq 0 ]]; then
  SSH_BASE_OPTS+=(-o LogLevel=ERROR)
  SSH_PW_OPTS+=(-o LogLevel=ERROR)
fi

RESULT_DIR="$(mktemp -d)"
trap 'rm -rf "$RESULT_DIR"' EXIT

SSH_BASE_OPTS_STR="${SSH_BASE_OPTS[*]}"
SSH_PW_OPTS_STR="${SSH_PW_OPTS[*]}"
export SSH_USER COMMAND SSH_BASE_OPTS_STR SSH_PW_OPTS_STR RESULT_DIR VERBOSE

# sshpass -e reads the password from $SSHPASS, which keeps it out of
# the process list (unlike sshpass -p)
if [[ -n "$SSH_PASSWORD" ]]; then
  export SSHPASS="$SSH_PASSWORD"
fi
unset SSH_PASSWORD

run_one() {
  local host="$1"
  local target="$host"
  [[ -n "$SSH_USER" ]] && target="${SSH_USER}@${host}"

  # shellcheck disable=SC2206
  local ssh_opts=($SSH_BASE_OPTS_STR)

  local out
  local rc
  if out=$(ssh "${ssh_opts[@]}" "$target" -- "$COMMAND" 2>&1 </dev/null); then
    rc=0
  else
    rc=$?
  fi

  # Fall back to password auth only when the host was reachable but
  # rejected key auth (rc 255 + "Permission denied"). Unreachable hosts,
  # DNS failures, timeouts, etc. are not retried.
  local used_pw=0
  if [[ "$rc" -eq 255 && -n "${SSHPASS:-}" ]] && grep -qiE 'permission denied|too many authentication failures' <<< "$out"; then
    # shellcheck disable=SC2206
    local ssh_pw_opts=($SSH_PW_OPTS_STR)
    used_pw=1
    touch "$RESULT_DIR/$host.pw"
    if out=$(sshpass -e ssh "${ssh_pw_opts[@]}" "$target" -- "$COMMAND" 2>&1 </dev/null); then
      rc=0
    else
      rc=$?
    fi
  fi

  # Decide whether a failure came from ssh itself (connection/auth) or
  # from the remote command. ssh uses 255 for its own errors, sshpass
  # uses 5 for a rejected password and 6 for an unknown host key. A
  # remote command can also exit 255, so we only call it an ssh failure
  # when the output looks like an ssh error message.
  local conn_reason=""
  if [[ "$used_pw" -eq 1 && "$rc" -eq 5 ]]; then
    conn_reason="password rejected"
  elif [[ "$used_pw" -eq 1 && "$rc" -eq 6 ]]; then
    conn_reason="host key unknown (sshpass)"
  elif [[ "$rc" -eq 255 ]]; then
    case "$out" in
      *"Could not resolve hostname"*)            conn_reason="DNS lookup failed" ;;
      *"Connection timed out"*|*"Operation timed out"*) conn_reason="connection timed out" ;;
      *"Connection refused"*)                   conn_reason="connection refused" ;;
      *"No route to host"*)                     conn_reason="no route to host" ;;
      *"Network is unreachable"*)               conn_reason="network unreachable" ;;
      *"Host key verification failed"*|*"REMOTE HOST IDENTIFICATION HAS CHANGED"*) conn_reason="host key mismatch" ;;
      *"Permission denied"*|*"Too many authentication failures"*)
        if [[ -n "${SSHPASS:-}" ]]; then conn_reason="key and password auth failed"; else conn_reason="key auth failed (no password given)"; fi ;;
      *"Connection closed"*|*"Connection reset"*|*"kex_exchange_identification"*) conn_reason="connection closed by remote host" ;;
      ssh:*|*$'\n'ssh:*)                        conn_reason="$(grep -m1 '^ssh:' <<< "$out" | sed 's/^ssh: //')" ;;
    esac
  fi

  if [[ -n "$conn_reason" ]]; then
    echo "$conn_reason" > "$RESULT_DIR/$host.conn"
  elif [[ "$rc" -ne 0 ]]; then
    echo "$rc" > "$RESULT_DIR/$host.cmdfail"
  fi

  # Prefix every output line with the hostname, like knife ssh did.
  # In quiet mode, ssh's own error text is withheld (it's summarized
  # at the end instead); only real command output is shown.
  if [[ "$VERBOSE" -eq 1 && "$used_pw" -eq 1 ]]; then
    printf '%-40s | [key auth rejected; used password auth]\n' "$host" >&2
  fi
  if [[ -n "$out" && ( -z "$conn_reason" || "$VERBOSE" -eq 1 ) ]]; then
    while IFS= read -r line; do
      printf '%-40s | %s\n' "$host" "$line"
    done <<< "$out"
  fi

  if [[ "$VERBOSE" -eq 1 && "$rc" -ne 0 ]]; then
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

# print_section TITLE EXT [FORMAT]
# Lists every host that has a $RESULT_DIR/<host>.<EXT> file, sorted,
# with the file's contents as the detail column.
print_section() {
  local title="$1" ext="$2" fmt="${3:-%s}"
  local files=("$RESULT_DIR"/*."$ext")
  [[ -e "${files[0]}" ]] || return 0
  echo ""
  echo "$title (${#files[@]}):"
  local f host detail
  for f in "${files[@]}"; do
    host="$(basename "$f" ".$ext")"
    detail="$(cat "$f")"
    # shellcheck disable=SC2059
    printf "  %-44s $fmt\n" "$host" "$detail"
  done | sort
}

echo ""
echo "Done. $TOTAL node(s) targeted. $((TOTAL - FAIL_COUNT)) succeeded, $FAIL_COUNT failed."

print_section "Could not connect" conn
print_section "Command exited non-zero" cmdfail "exit code %s"

PW_FILES=("$RESULT_DIR"/*.pw)
if [[ -e "${PW_FILES[0]}" ]]; then
  echo ""
  echo "Key auth rejected, password fallback tried (${#PW_FILES[@]}) - consider deploying your key:"
  for f in "${PW_FILES[@]}"; do
    printf '  %s\n' "$(basename "$f" .pw)"
  done | sort
fi
