#!/bin/sh
# install.sh [--prefix DIR] [--yes] [--path] [--zellij-baseline] [--ghostty-baseline] [--update|--uninstall]:
# install zellij-claude-workspace. bootstrap.sh (the curl one-liner) clones the
# repo and runs this from the clone; it also works from any checkout.
# Asks for the key locations (each with a default), shows what it will do, and
# proceeds only on a yes. --yes, or a stdin that is not a terminal, takes the
# defaults (and --prefix) without asking.
# Symlinks the bin/ commands into the bin directory — symlinks work because the
# scripts resolve their real directory (${0:A:h}) to find lib/ and share/.
# Copies examples/claude.kdl to the layout path and writes the config file,
# each only when absent. Leaves zellij's config.kdl alone and prints the
# settings to add, unless asked to replace it with examples/config.kdl.baseline;
# likewise Ghostty's config with examples/config.ghostty.baseline. Both are
# opt-in (a question, or --zellij-baseline / --ghostty-baseline), and a file
# being replaced is first copied to <file>.bak.<timestamp>. Idempotent.
# Checks the bin directory the way the panes will see it — from a login zsh,
# since they run `zsh -lc` — and offers to add it to ~/.zprofile when it is
# missing there (--path says yes without asking). Needs zsh and python3; warns
# about a missing claude or a zellij older than 0.44.
# --update is the update path (zupdate, bootstrap.sh on an existing clone):
# no questions, relinks the commands (new ones get linked, links to removed
# ones are cleaned up), runs `ztab --heal`, and touches nothing else.
# --uninstall removes only symlinks that point into this repo; config and
# layout files are left alone.

set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
cfgdir="${XDG_CONFIG_HOME:-$HOME/.config}/zellij-claude-workspace"
default_layout="$HOME/.config/zellij/layouts/claude.kdl"
prefix="$HOME/.local/bin"
layout="${ZCW_LAYOUT:-$default_layout}"
dirs=""
zellij_cfg="${ZELLIJ_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zellij}/config.kdl"
ghostty_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
ghostty_mac="$HOME/Library/Application Support/com.mitchellh.ghostty"
# Ghostty >= 1.2 reads config.ghostty; replace a legacy `config` if that is all there is
if [ ! -e "$ghostty_dir/config.ghostty" ] && [ -e "$ghostty_dir/config" ]; then
  ghostty_cfg="$ghostty_dir/config"
else
  ghostty_cfg="$ghostty_dir/config.ghostty"
fi
zellij_baseline=0
ghostty_baseline=0
uninstall=0
update=0
path_fix=0
ask=1
zprofile="${ZDOTDIR:-$HOME}/.zprofile"

usage() { echo "usage: install.sh [--prefix DIR] [--yes] [--path] [--zellij-baseline] [--ghostty-baseline] [--update|--uninstall]"; }
while [ $# -gt 0 ]; do
  case $1 in
    --prefix) [ $# -ge 2 ] || { echo "install.sh: --prefix needs a directory" >&2; exit 2; }
              prefix=$2; shift 2 ;;
    -y|--yes) ask=0; shift ;;
    --zellij-baseline) zellij_baseline=1; shift ;;
    --ghostty-baseline) ghostty_baseline=1; shift ;;
    --path) path_fix=1; shift ;;
    --update) update=1; ask=0; shift ;;
    --uninstall) uninstall=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[ -t 0 ] || ask=0
prefix=${prefix%/}

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

# yesno <question> <default 0|1>: print 1 for yes, 0 for no
yesno() {
  if [ "$2" -eq 1 ]; then printf '%s [Y/n]: ' "$1" >&2; else printf '%s [y/N]: ' "$1" >&2; fi
  read -r _y_reply || _y_reply=
  case $_y_reply in
    [Yy]|[Yy][Ee][Ss]) echo 1 ;;
    [Nn]|[Nn][Oo]) echo 0 ;;
    *) echo "$2" ;;
  esac
}

# plan_baseline <label> <file>: one plan line for replacing <file> with a baseline
plan_baseline() {
  if [ -e "$2" ]; then
    printf '  %-9s replace %s with the baseline (old one kept as .bak.<timestamp>)\n' "$1" "$2"
  else
    printf '  %-9s create %s from the baseline\n' "$1" "$2"
  fi
}

# apply_baseline <rendered file> <target>: install it, backing up a different
# existing target first; removes the rendered file
apply_baseline() {
  if [ -e "$2" ] && cmp -s "$1" "$2"; then
    rm -f "$1"
    echo "kept $2 (already matches the baseline)"
    return
  fi
  mkdir -p "$(dirname "$2")"
  if [ -e "$2" ]; then
    _b_bak="$2.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$2" "$_b_bak"
    echo "backed up $2 to $_b_bak"
  fi
  cat "$1" > "$2"   # writes through a symlinked config (dotfiles) instead of replacing it
  rm -f "$1"
  echo "installed baseline $2"
}

# on_login_path <dir>: whether a login zsh — what the panes run — has <dir>
# on PATH. The installer's own PATH can say yes while the panes say no, e.g.
# when ~/.zshrc adds it, which `zsh -lc` never reads.
on_login_path() {
  case ":$(zsh -lc 'printf %s "$PATH"' 2>/dev/null):" in
    *":$1:"*) return 0 ;;
  esac
  return 1
}

# link_commands: symlink bin/* into $prefix, and remove links there that point
# into this repo's bin/ at a command that no longer exists
link_commands() {
  mkdir -p "$prefix"
  for src in "$here"/bin/*; do
    [ -f "$src" ] || continue   # lib/ stays put: the scripts find it via their real path
    dst="$prefix/$(basename "$src")"
    if [ -e "$dst" ] && [ ! -L "$dst" ]; then
      echo "skipped $dst (exists and is not a symlink)" >&2
      continue
    fi
    [ "$(readlink "$dst" 2>/dev/null)" = "$src" ] && continue
    ln -sfn "$src" "$dst"
    echo "linked $dst"
  done
  for dst in "$prefix"/*; do
    [ -L "$dst" ] && [ ! -e "$dst" ] || continue
    case $(readlink "$dst") in
      "$here"/bin/*) rm "$dst"; echo "removed $dst (no longer a command)" ;;
    esac
  done
}

# path_line: the ~/.zprofile line that puts $prefix on PATH, $HOME kept symbolic
path_line() {
  case $prefix in
    "$HOME"/*) printf 'export PATH="$HOME/%s:$PATH"' "${prefix#"$HOME"/}" ;;
    *) printf 'export PATH="%s:$PATH"' "$prefix" ;;
  esac
}

# finish: put $prefix on the login PATH if agreed, then say what is still
# missing for the panes to start
finish() {
  if [ "$path_ok" -eq 0 ] && [ "$path_fix" -eq 1 ]; then
    printf '\n# zellij-claude-workspace: the commands, for login shells (zellij panes run zsh -lc)\n%s\n' "$(path_line)" >> "$zprofile"
    echo "added $prefix to PATH in $zprofile"
    path_ok=1
  fi
  _f_left=""
  if [ "$path_ok" -eq 0 ]; then
    _f_left="$_f_left
  add $prefix to PATH for login shells — append to $zprofile:
    $(path_line)"
  fi
  if ! zsh -lc 'command -v claude' >/dev/null 2>&1; then
    _f_left="$_f_left
  put claude on PATH for login shells ($zprofile); a login zsh cannot find it"
  fi
  if [ -n "$_f_left" ]; then
    echo
    echo "Before the workspace will start:$_f_left"
    echo "then open a new terminal."
  fi
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
  echo "the code itself stays in $here; delete it to remove it too"
  exit 0
fi

# prerequisites: the scripts are zsh, and claude_create_or_resume needs python3
_missing=""
for cmd in zsh python3; do
  command -v "$cmd" >/dev/null 2>&1 || _missing="$_missing $cmd"
done
[ -z "$_missing" ] || { echo "install.sh: needs$_missing; install it and run again" >&2; exit 1; }
if command -v zellij >/dev/null 2>&1; then
  _zv=$(zellij --version 2>/dev/null | awk '{print $2}')
  _zmaj=${_zv%%.*}; _zmin=${_zv#*.}; _zmin=${_zmin%%.*}
  case $_zmaj$_zmin in
    ''|*[!0-9]*) ;;
    *) [ "$_zmaj" -gt 0 ] || [ "$_zmin" -ge 44 ] ||
         echo "warning: zellij $_zv is older than 0.44, which ztab needs" >&2 ;;
  esac
else
  echo "warning: zellij not found on PATH; install it before running zstart" >&2
fi
command -v claude >/dev/null 2>&1 || echo "warning: claude not found on PATH; install Claude Code before running zstart" >&2

if on_login_path "$prefix"; then path_ok=1; else path_ok=0; fi

if [ "$update" -eq 1 ]; then
  link_commands
  zsh "$here/bin/ztab" --heal || echo "warning: ztab --heal failed; run it by hand" >&2
  finish
  exit 0
fi

if [ "$ask" -eq 1 ]; then
  echo "zellij-claude-workspace installer — press Enter to accept a default."
  echo
  prefix=$(prompt "Bin directory for the commands (should be on PATH)" "$prefix")
  layout=$(prompt "Workspace layout file" "$layout")
  printf 'Project folders for `ztab --create <name>`, space-separated [none]: ' >&2
  read -r dirs || dirs=
  [ "$zellij_baseline" -eq 1 ] ||
    zellij_baseline=$(yesno "Replace zellij's $zellij_cfg with the baseline from examples/?" 0)
  [ "$ghostty_baseline" -eq 1 ] ||
    ghostty_baseline=$(yesno "Replace Ghostty's $ghostty_cfg with the baseline from examples/?" 0)
  prefix=${prefix%/}
  if on_login_path "$prefix"; then path_ok=1; else path_ok=0; fi
  [ "$path_ok" -eq 1 ] || [ "$path_fix" -eq 1 ] ||
    path_fix=$(yesno "$prefix is not on a login shell's PATH, which the panes need. Add it to $zprofile?" 1)
fi

expanded_dirs=""
for d in $dirs; do
  expanded_dirs="$expanded_dirs${expanded_dirs:+ }$(untilde "$d")"
done

echo
echo "Install plan:"
echo "  commands  link into $prefix"
[ "$path_ok" -eq 1 ] || [ "$path_fix" -eq 0 ] || echo "  path      add $prefix to PATH in $zprofile"
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
[ "$zellij_baseline" -eq 0 ] || plan_baseline zellij "$zellij_cfg"
[ "$ghostty_baseline" -eq 0 ] || plan_baseline ghostty "$ghostty_cfg"
confirm
echo

link_commands

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

# default_layout takes a name from zellij's layouts dir, or a path
if [ "$layout" = "$default_layout" ]; then
  layout_setting='default_layout "claude"'
else
  layout_setting="default_layout \"$layout\""
fi

if [ "$zellij_baseline" -eq 1 ]; then
  tmp=$(mktemp)
  sed "s|^default_layout .*|$layout_setting|" "$here/examples/config.kdl.baseline" > "$tmp"
  apply_baseline "$tmp" "$zellij_cfg"
fi

if [ "$ghostty_baseline" -eq 1 ]; then
  tmp=$(mktemp)
  cp "$here/examples/config.ghostty.baseline" "$tmp"
  apply_baseline "$tmp" "$ghostty_cfg"
  # on macOS Ghostty also loads this one, after the XDG file, so it wins
  for f in "$ghostty_mac/config.ghostty" "$ghostty_mac/config"; do
    [ ! -e "$f" ] || echo "warning: $f also exists and overrides $ghostty_cfg; merge or remove it" >&2
  done
fi

if [ "$zellij_baseline" -eq 0 ]; then
  echo
  echo "Add these settings to your zellij config.kdl (not edited for you):"
  echo
  sed "s|^default_layout .*|$layout_setting|" "$here/examples/config.kdl.snippet" | sed 's/^/    /'
fi

finish
