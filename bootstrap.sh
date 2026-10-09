#!/bin/sh
# bootstrap.sh: install or update zellij-claude-workspace in one command —
#   curl -fsSL https://raw.githubusercontent.com/rzen/zellij-claude-workspace/main/bootstrap.sh | sh
# Flags go to install.sh:
#   curl -fsSL .../bootstrap.sh | sh -s -- --yes --prefix ~/bin
# Clones the repo into ${ZCW_HOME:-~/.local/share/zellij-claude-workspace} and
# runs its install.sh, which links the commands into ~/.local/bin. When the
# clone is already there this is an update instead: fast-forward the clone,
# then `install.sh --update` (relink, ztab --heal). A clone with local changes
# is left alone. install.sh's questions read the terminal, not the pipe this
# script arrived on. Everything runs from main() on the last line, so a
# download cut short runs nothing.
#   ZCW_HOME  where the clone lives
#   ZCW_REPO  what to clone (default the GitHub repo)

set -eu

die() { echo "bootstrap: $*" >&2; exit 1; }

main() {
  repo=${ZCW_REPO:-https://github.com/rzen/zellij-claude-workspace.git}
  home=${ZCW_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/zellij-claude-workspace}

  command -v git >/dev/null 2>&1 || die "needs git (on macOS: xcode-select --install)"

  if [ -e "$home" ]; then
    [ -f "$home/install.sh" ] && [ -f "$home/bin/ztab" ] &&
      [ "$(git -C "$home" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$home" && pwd -P)" ] ||
      die "$home exists but is not a clone of zellij-claude-workspace; move it aside or set ZCW_HOME"
    [ -z "$(git -C "$home" status --porcelain --untracked-files=no)" ] ||
      die "$home has local changes; commit or discard them, then run again"
    old=$(git -C "$home" rev-parse HEAD)
    git -C "$home" pull --ff-only --quiet || die "could not update $home (git pull --ff-only failed)"
    new=$(git -C "$home" rev-parse HEAD)
    if [ "$old" = "$new" ]; then
      echo "zellij-claude-workspace is up to date ($home)"
    else
      echo "updated $home:"
      git -C "$home" log --oneline "$old..$new" | sed 's/^/  /'
    fi
    sh "$home/install.sh" --update "$@"
    return
  fi

  mkdir -p "$(dirname "$home")"
  git clone --quiet "$repo" "$home" || die "could not clone $repo"
  echo "cloned $repo into $home"
  # piped in, stdin is this script; give install.sh the terminal for its questions
  if [ -t 0 ] || ! (exec </dev/tty) 2>/dev/null; then
    sh "$home/install.sh" "$@"
  else
    sh "$home/install.sh" "$@" </dev/tty
  fi
}

main "$@"
