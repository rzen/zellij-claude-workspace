#!/bin/sh
# install.sh [--prefix DIR] [--yes] [--uninstall]: install zellij-claude-workspace.
# Asks for the key locations (each with a default), shows what it will do, and
# proceeds only on a yes. --yes, or a stdin that is not a terminal, takes the
# defaults (and --prefix) without asking.
# Symlinks the bin/ commands into the bin directory — symlinks work because the
# scripts resolve their real directory (${0:A:h}) to find lib/ and share/.
# Copies examples/claude.kdl to the layout path and writes the config file,
# each only when absent, and never edits zellij's config.kdl: it prints the
# settings to add. Idempotent.
# --uninstall removes only symlinks that point into this repo; config and
# layout files are left alone.

set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
cfgdir="${XDG_CONFIG_HOME:-$HOME/.config}/zellij-claude-workspace"
default_layout="$HOME/.config/zellij/layouts/claude.kdl"
prefix="$HOME/.local/bin"
layout="${ZCW_LAYOUT:-$default_layout}"
dirs=""
uninstall=0
ask=1

usage() { echo "usage: install.sh [--prefix DIR] [--yes] [--uninstall]"; }
while [ $# -gt 0 ]; do
  case $1 in
    --prefix) [ $# -ge 2 ] || { echo "install.sh: --prefix needs a directory" >&2; exit 2; }
              prefix=$2; shift 2 ;;
    -y|--yes) ask=0; shift ;;
    --uninstall) uninstall=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[ -t 0 ] || ask=0

# expand a leading ~ the way a shell would; read leaves it literal
untilde() {
  case $1 in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# prompt <question> <default>: print the answer, or the default on an empty reply
prompt() {
  printf '%s [%s]: ' "$1" "$2" >&2
  read -r _p_reply || _p_reply=
  untilde "${_p_reply:-$2}"
}

confirm() {
  [ "$ask" -eq 1 ] || return 0
  printf '\nProceed? [y/N] ' >&2
  read -r _c_reply || _c_reply=
  case $_c_reply in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) echo "Nothing changed." >&2; exit 1 ;;
  esac
}

if [ "$uninstall" -eq 1 ]; then
  [ "$ask" -eq 0 ] || prefix=$(prompt "Bin directory to remove links from" "$prefix")
  echo
  echo "Will remove the symlinks in $prefix that point into $here."
  confirm
  for src in "$here"/bin/*; do
    [ -f "$src" ] || continue
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

if [ "$ask" -eq 1 ]; then
  echo "zellij-claude-workspace installer — press Enter to accept a default."
  echo
  prefix=$(prompt "Bin directory for the commands (should be on PATH)" "$prefix")
  layout=$(prompt "Workspace layout file" "$layout")
  printf 'Project folders for `ztab --create <name>`, space-separated [none]: ' >&2
  read -r dirs || dirs=
fi

expanded_dirs=""
for d in $dirs; do
  expanded_dirs="$expanded_dirs${expanded_dirs:+ }$(untilde "$d")"
done

echo
echo "Install plan:"
echo "  commands  link into $prefix"
if [ -e "$layout" ]; then
  echo "  layout    keep existing $layout"
else
  echo "  layout    create $layout (one Home tab at \$HOME)"
fi
if [ -e "$cfgdir/config" ]; then
  echo "  config    keep existing $cfgdir/config"
else
  echo "  config    create $cfgdir/config"
fi
[ -z "$expanded_dirs" ] || echo "  projects  $expanded_dirs"
confirm
echo

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

# the settings that differ from the defaults, as config-file lines
settings=""
[ "$layout" = "$default_layout" ] || settings=": \${ZCW_LAYOUT:=\"$layout\"}"
if [ -n "$expanded_dirs" ]; then
  arr=""
  for d in $expanded_dirs; do arr="$arr${arr:+ }\"$d\""; done
  settings="$settings${settings:+
}ZCW_PROJECT_DIRS=($arr)"
fi

if [ -e "$cfgdir/config" ]; then
  echo "kept existing config $cfgdir/config"
  if [ -n "$settings" ]; then
    echo "  add these lines to it for the choices above:"
    printf '%s\n' "$settings" | sed 's/^/    /'
  fi
else
  mkdir -p "$cfgdir"
  {
    cat "$here/examples/config"
    if [ -n "$settings" ]; then
      printf '\n# Set by install.sh\n%s\n' "$settings"
    fi
  } > "$cfgdir/config"
  echo "installed config $cfgdir/config"
fi

for cmd in zellij claude python3 zsh; do
  command -v "$cmd" >/dev/null 2>&1 || echo "warning: $cmd not found on PATH" >&2
done
case ":$PATH:" in
  *":$prefix:"*) ;;
  *) echo "warning: $prefix is not on PATH; add it in ~/.zprofile (panes run zsh -lc)" >&2 ;;
esac

# default_layout takes a name from zellij's layouts dir, or a path
if [ "$layout" = "$default_layout" ]; then
  layout_setting='default_layout "claude"'
else
  layout_setting="default_layout \"$layout\""
fi
echo
echo "Add these settings to your zellij config.kdl (not edited for you):"
echo
sed "s|^default_layout .*|$layout_setting|" "$here/examples/config.kdl.snippet" | sed 's/^/    /'
