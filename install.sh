#!/bin/sh
# install.sh [--prefix DIR] [--uninstall]: install zellij-claude-workspace.
# Symlinks the bin/ commands into DIR (default $HOME/.local/bin) — symlinks
# work because the scripts resolve their real directory (${0:A:h}) to find
# lib/ and share/. Copies examples/claude.kdl to the layout path and
# examples/config to the config dir, each only when absent, and never edits
# zellij's config.kdl: it prints the settings to add. Idempotent.
# --uninstall removes only symlinks that point into this repo; copied config
# and layout files are left alone.

set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
prefix="$HOME/.local/bin"
uninstall=0

while [ $# -gt 0 ]; do
  case $1 in
    --prefix) [ $# -ge 2 ] || { echo "install.sh: --prefix needs a directory" >&2; exit 2; }
              prefix=$2; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    -h|--help) echo "usage: install.sh [--prefix DIR] [--uninstall]"; exit 0 ;;
    *) echo "usage: install.sh [--prefix DIR] [--uninstall]" >&2; exit 2 ;;
  esac
done

cfgdir="${XDG_CONFIG_HOME:-$HOME/.config}/zellij-claude-workspace"
layout="${ZCW_LAYOUT:-$HOME/.config/zellij/layouts/claude.kdl}"

if [ "$uninstall" -eq 1 ]; then
  for src in "$here"/bin/*; do
    dst="$prefix/$(basename "$src")"
    if [ -L "$dst" ]; then
      case $(readlink "$dst") in
        "$here"/*) rm "$dst"; echo "removed $dst" ;;
        *) echo "kept $dst (not ours)" ;;
      esac
    fi
  done
  exit 0
fi

mkdir -p "$prefix"
for src in "$here"/bin/*; do
  [ -f "$src" ] || continue   # lib/ stays put: the scripts find it via their real path
  dst="$prefix/$(basename "$src")"
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    echo "skipped $dst (exists and is not a symlink)" >&2
    continue
  fi
  ln -sfn "$src" "$dst"
  echo "linked $dst"
done

if [ -e "$layout" ]; then
  echo "kept existing layout $layout"
else
  mkdir -p "$(dirname "$layout")"
  # the Home tab starts in $HOME; KDL strings can't hold a quote or backslash
  sed "s|cwd=\"/path/to/project\"|cwd=\"$HOME\"|" "$here/examples/claude.kdl" > "$layout"
  echo "installed example layout $layout (one Home tab; add projects with ztab --create)"
fi

if [ -e "$cfgdir/config" ]; then
  echo "kept existing config $cfgdir/config"
else
  mkdir -p "$cfgdir"
  cp "$here/examples/config" "$cfgdir/config"
  echo "installed example config $cfgdir/config"
fi

for cmd in zellij claude python3 zsh; do
  command -v "$cmd" >/dev/null 2>&1 || echo "warning: $cmd not found on PATH" >&2
done
case ":$PATH:" in
  *":$prefix:"*) ;;
  *) echo "warning: $prefix is not on PATH; add it in ~/.zprofile (panes run zsh -lc)" >&2 ;;
esac

echo
echo "Add these settings to your zellij config.kdl (not edited for you):"
echo
sed 's/^/    /' "$here/examples/config.kdl.snippet"
