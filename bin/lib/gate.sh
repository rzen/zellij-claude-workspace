#!/bin/sh
# gate.sh — "one instance per key" gate, used by claude_create_or_resume.
# Source it; it defines functions and nothing else.
#
# POSIX sh on purpose, so both bash and zsh can source it. So: no [[ ]], no arrays,
# no ${var//}, every expansion quoted, and nothing that depends on word-splitting an unquoted
# *parameter* (zsh does not split those; it does split command substitution).
#
# Used here for one thing: claude_create_or_resume's wait-then-refuse gate
# (gate_wait). The rest — gate_acquire, gate_run, gate_release — is a small
# mkdir-lock kit kept for scripts that want a real lock instead of a pgrep.
#
# Two bugs that hand-rolled `mkdir` locks tend to have, both fixed here:
#
#   1. `trap 'rm -rf "$LOCK"' EXIT INT TERM` never exits. On TERM bash ran the
#      handler, deleted the lock, and then kept running without one. The traps
#      installed here exit (128+signo), so gate_release runs exactly once, from
#      the EXIT trap, and the process really goes away.
#
#   2. A trap is deferred until the current FOREGROUND child returns, so a
#      script sitting in a long-running child ignores a pending TERM until that
#      child ends, leaving an orphan holding the lock. gate_run starts the
#      child in the background and `wait`s on it: wait is interruptible, so the
#      trap fires immediately and the EXIT handler kills the child tree before
#      removing the lock.
#
# Typical use:
#   . "$(dirname "$0")/lib/gate.sh"
#   gate_wait "label" 5 finder_fn || exit 1   # wait-then-refuse, no lock at all
#   KEY=$(gate_key "$ROOT")
#   gate_acquire myname "$KEY" 5 || exit 1    # sets GATE_LOCK, installs traps
#   gate_run some_long_command args...        # interruptible
#
# Globals: GATE_TMP (${TMPDIR:-/tmp} with no trailing slash — the base for every
# lock, state and log path), GATE_LOCK (lock dir once acquired), GATE_CHILD (pid
# of the running gate_run child), GATE_HOLDER (last pid seen holding the gate).

GATE_LOCK=
GATE_CHILD=
GATE_HOLDER=

# Temp base with no trailing slash: macOS sets TMPDIR with one, so appending
# "/…" to a raw ${TMPDIR:-/tmp} spells a double slash (same directory, ugly in
# logs and banners). Two steps — POSIX sh cannot nest the two expansions. One
# slash is stripped, never more: a TMPDIR of "/" becomes "" and every path
# lands at the root, which is no worse than the "//" it built before.
GATE_TMP="${TMPDIR:-/tmp}"
GATE_TMP="${GATE_TMP%/}"

# gate_key <path> — stable short key for a project root.
gate_key() {
  printf '%s' "$1" | shasum | cut -c1-12
}

# _gate_descendants <pid> — every descendant pid, one per line, parents before
# children. Printed rather than returned so callers need no arrays.
# The `|| :` matters: a childless pid makes pgrep exit 1, and under the callers'
# `set -e -o pipefail` that would abort the EXIT trap before it frees the lock.
_gate_descendants() {
  pgrep -P "$1" 2>/dev/null | while read -r _gd_kid; do
    [ -n "$_gd_kid" ] || continue
    printf '%s\n' "$_gd_kid"
    _gate_descendants "$_gd_kid" || :
  done || :
  return 0
}

# gate_killtree <pid> — TERM a child and everything under it, then reap it.
# The descendants are collected BEFORE anything is signalled and the parent is
# killed FIRST, so a supervisor loop cannot respawn a child in
# between. No escalation to KILL: these children exit on TERM.
gate_killtree() {
  _gk_pid="$1"
  [ -n "$_gk_pid" ] || return 0
  _gk_kids=$(_gate_descendants "$_gk_pid") || :
  kill -TERM "$_gk_pid" 2>/dev/null || :
  if [ -n "$_gk_kids" ]; then
    printf '%s\n' "$_gk_kids" | while read -r _gk_kid; do
      [ -n "$_gk_kid" ] || continue
      kill -TERM "$_gk_kid" 2>/dev/null || :
    done
  fi
  wait "$_gk_pid" 2>/dev/null || :
  return 0
}

# gate_run <cmd> [args...] — run a command as an interruptible foreground step.
# The command (a program or a shell function) runs in the background and the
# caller `wait`s, so a signal is handled the moment it arrives instead of after
# the child finally returns. Returns the child's exit status; shell options
# such as `set -o pipefail` are inherited by the subshell, so a wrapped
# pipeline still reports the status the caller expects.
gate_run() {
  _gr_rc=0
  # 0<&0: a background job's stdin defaults to /dev/null; keep the caller's
  # (the pane's tty) so a wrapped command sees exactly what a foreground one did.
  "$@" 0<&0 &
  GATE_CHILD=$!
  wait "$GATE_CHILD" || _gr_rc=$?
  GATE_CHILD=
  return "$_gr_rc"
}

# gate_release — drop everything this process holds. Idempotent; safe to call
# from an EXIT trap.
gate_release() {
  if [ -n "${GATE_CHILD:-}" ]; then
    _grl_child="$GATE_CHILD"
    GATE_CHILD=
    gate_killtree "$_grl_child"
  fi
  if [ -n "${GATE_LOCK:-}" ]; then
    rm -rf "$GATE_LOCK" 2>/dev/null || :
    GATE_LOCK=
  fi
  return 0
}

# gate_wait <label> <secs> <finder> — the shared wait-then-refuse policy.
# <finder> names a shell function that prints the pid of a LIVE holder, or
# nothing. A holder on its way out (a pane just closed, a loop shutting down)
# lets go within a second or two; a real duplicate does not. Polls every 0.2s
# for up to <secs>, returns 0 the moment the gate is clear, otherwise prints
# the refusal and returns 1. Leaves the last pid seen in GATE_HOLDER.
gate_wait() {
  _gw_label="$1"
  _gw_secs="$2"
  _gw_finder="$3"
  _gw_tries=$(( _gw_secs * 5 ))
  [ "$_gw_tries" -ge 1 ] || _gw_tries=1
  _gw_i=0
  _gw_seen=0
  GATE_HOLDER=
  while :; do
    GATE_HOLDER=$("$_gw_finder" 2>/dev/null) || :
    [ -n "$GATE_HOLDER" ] || return 0
    if [ "$_gw_seen" -eq 0 ]; then
      _gw_seen=1
      echo "$_gw_label: held by pid $GATE_HOLDER; waiting for it to exit..." >&2
    fi
    _gw_i=$(( _gw_i + 1 ))
    [ "$_gw_i" -lt "$_gw_tries" ] || break
    sleep 0.2
  done
  echo "$_gw_label: already running (pid $GATE_HOLDER); not starting another" >&2
  return 1
}

# _gate_lock_holder — the finder for gate_acquire: the lock's pid if it is
# alive, nothing if the lock is unheld, stale, or half-written.
_gate_lock_holder() {
  [ -n "${GATE_LOCK:-}" ] || return 0
  [ -f "$GATE_LOCK/pid" ] || return 0
  _glh_pid=$(cat "$GATE_LOCK/pid" 2>/dev/null) || return 0
  [ -n "$_glh_pid" ] || return 0
  kill -0 "$_glh_pid" 2>/dev/null || return 0
  printf '%s\n' "$_glh_pid"
}

# gate_acquire <name> <key> [wait_secs] — take $GATE_TMP/<name>-<key>.lock
# or refuse. A dead holder's lock is broken rather than inherited; a live one is
# waited on (gate_wait policy, default 5s) and then refused. On success the lock
# holds this pid and the traps that guarantee it is given back.
gate_acquire() {
  _ga_name="$1"
  _ga_key="$2"
  _ga_wait="${3:-5}"
  _ga_waited=0
  _ga_breaks=0
  GATE_LOCK="$GATE_TMP/$_ga_name-$_ga_key.lock"
  while :; do
    if mkdir "$GATE_LOCK" 2>/dev/null; then
      echo $$ > "$GATE_LOCK/pid"
      # Every path out of the process runs gate_release exactly once: the
      # signal traps only set an exit status, EXIT does the cleanup.
      trap gate_release EXIT
      trap 'exit 143' TERM
      trap 'exit 130' INT
      trap 'exit 129' HUP
      return 0
    fi
    _ga_holder=$(_gate_lock_holder) || :
    if [ -z "$_ga_holder" ]; then
      # Dead, empty or half-written holder: break it and retry at once.
      _ga_breaks=$(( _ga_breaks + 1 ))
      if [ "$_ga_breaks" -gt 10 ]; then
        echo "$_ga_name: $GATE_LOCK keeps reappearing unheld; not starting another" >&2
        GATE_LOCK=
        return 1
      fi
      rm -rf "$GATE_LOCK" 2>/dev/null || :
      continue
    fi
    if [ "$_ga_waited" -ne 0 ]; then
      # Already waited out one holder and lost the race for the lock.
      echo "$_ga_name: already running (pid $_ga_holder); not starting another" >&2
      GATE_LOCK=
      return 1
    fi
    _ga_waited=1
    gate_wait "$_ga_name" "$_ga_wait" _gate_lock_holder || { GATE_LOCK=; return 1; }
  done
}
