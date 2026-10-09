# zellij-claude-workspace

One persistent [zellij](https://zellij.dev) session holding one tab per
project. Each tab is a set of named, auto-resuming [Claude Code](https://claude.com/claude-code)
sessions plus a shell:

```
+-------------------+-------------------+-------------------+
|                   |                   |  <Tab> Scratch    |
|  <Tab> Watch      |  <Tab> Main       |  (claude)         |
|  (claude)         |  (claude)         +-------------------+
|                   |                   |  <Tab> Shell      |
+-------------------+-------------------+-------------------+
```

The layout file is the source of truth. `ztab` toggles its tabs on and off in
the running session and remembers the state in the file.

## Key features

- One workspace session (`main` by default); `zstart` attaches or rebuilds it from the layout.
- Named Claude Code sessions per pane: `claude_create_or_resume '<Tab> Main'` resumes the newest transcript with that name in the directory, or creates it on first use. The name survives `/clear`.
- Never two claudes on one session: a duplicate waits briefly, then refuses.
- `ztab` toggles any number of tabs (exact, case-insensitive or unique-prefix names), opening them in layout position; the toggle persists via KDL slashdash (`/-`).
- `ztab --create` appends a new tab from a template and opens it; `--reconfigure` rewrites a tab from the template; `--remove` removes one; `--heal` updates a layout written under older conventions.
- `zstop` tears everything down; `zstop --strays` (run by `zstart`) removes stray zellij sessions.
- `claude_list_sessions` lists Claude sessions for a directory (or all).
- One-line install from GitHub; `zupdate` (or the same one-liner) updates in place.
- Interactive installer: asks for the key locations, shows a plan, installs on a yes.
- Customizable: config file for session name, layout path, project directories, and a tab template.

## Requirements

- zellij 0.44 or newer (`list-tabs --state`, `close-tab-by-id`, `move-tab`)
- Claude Code (`claude` on PATH)
- python3, zsh, git; macOS or Linux

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/rzen/zellij-claude-workspace/main/bootstrap.sh | sh
```

This clones the repo into `~/.local/share/zellij-claude-workspace` (`ZCW_HOME`
overrides) and runs its `install.sh`, which asks its questions on the terminal
as usual. Pass installer flags after `sh -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/rzen/zellij-claude-workspace/main/bootstrap.sh | sh -s -- --yes --path
```

Or from a checkout of your own (the commands then link into it, so edits there
are live):

```sh
./install.sh                    # asks for locations, shows a plan, asks "Proceed?"
./install.sh --yes [--prefix DIR]   # no questions: defaults (and --prefix)
./install.sh --yes --path       # ...and add the bin directory to PATH in ~/.zprofile
./install.sh --yes --zellij-baseline --ghostty-baseline   # also apply the baseline configs
./install.sh --uninstall        # removes only symlinks pointing into this repo
```

The installer asks for three things, each with a default you can accept with
Enter: the bin directory for the commands (`~/.local/bin`), the layout file
(`~/.config/zellij/layouts/claude.kdl`), and the project folders
`ztab --create` should search (none). It then shows the plan and installs only
on a yes. It symlinks the commands into the bin directory, creates the layout
(one `Home` tab) and `~/.config/zellij-claude-workspace/config` with your
choices, each only if absent. It needs zsh and python3, and warns about a
missing `claude` or a zellij older than 0.44. Run without a terminal (CI) it
behaves like `--yes`.

The panes run `zsh -lc`, so the bin directory has to be on PATH for a login
shell, not just in `~/.zshrc`. The installer checks exactly that, and when it
is missing offers to add it to `~/.zprofile` (`--path` says yes without
asking); declined, it ends with the line to add yourself.

It also offers (default no) to replace your zellij `config.kdl` and Ghostty
config (`~/.config/ghostty/config.ghostty`) with the full baselines in
`examples/` — `config.kdl.baseline` and `config.ghostty.baseline`. A file being
replaced is first copied to `<file>.bak.<timestamp>`; one that already matches
is left alone. The Ghostty baseline starts `zstart` in the first window and
maps Cmd shortcuts to the zellij bindings in the zellij baseline, so the two
go together. On macOS, a config under
`~/Library/Application Support/com.mitchellh.ghostty/` overrides it; the
installer warns if one exists.

Without the zellij baseline, `config.kdl` is not edited; add the
settings from `examples/config.kdl.snippet`:

```kdl
default_layout "claude"
session_serialization false
on_force_close "detach"
```

- `session_serialization false`: no snapshots of dead sessions, so a rebuild always comes from the layout file, which stays the single source of truth.
- `on_force_close "detach"` (zellij's default): closing the terminal detaches instead of quitting, so the server and every claude in it keep running.
- `default_layout "claude"`: the layout name, matching `claude.kdl`.

The installed layout has one `Home` tab rooted at `$HOME`; add projects with `ztab --create <name> [path]`.

Panes run `zsh -lc`, so `claude` and these scripts must be on PATH from a login shell (`~/.zprofile`), not just `~/.zshrc`.

## Updating

```sh
zupdate
```

Fast-forwards the checkout the commands live in, links any new command and
cleans up links to removed ones, and runs `ztab --heal` so your layout follows
renamed conventions. Re-running the curl one-liner does the same. Your layout,
config and tab template are never replaced; a checkout with uncommitted
changes is left alone. Open tabs pick up a healed layout when reopened (or
after `zstop`, then `zstart`).

## Daily use

```sh
zstart                    # attach to the workspace, or build it from the layout
ztab                      # list tabs, which are open, and any stray sessions
ztab api web              # toggle tabs: close if open, else open in layout position
ztab -c mytool [path]     # append a tab (cwd: path, else a match in ZCW_PROJECT_DIRS, else $PWD) and open it
ztab -r mytool            # rewrite a tab from the template; reopen it if open
ztab -x mytool            # remove a tab from the layout; close it if open
ztab --heal               # bring an older layout (and a custom template) up to current conventions
zstop                     # kill every zellij session (panes resume on the next zstart)
zstop --strays            # kill only sessions other than the workspace
claude_list_sessions [-a] # Claude sessions for this directory (-a: all)
zupdate                   # update from the git remote, relink, heal the layout
```

`ztab` only works inside the workspace session, except `--heal`, which only
edits files. `--reconfigure` on the tab you are sitting in changes the file
only and tells you what to run from another tab.

## The layout is the source of truth

`ztab <tab>` lifts the tab's block out of the layout file and opens it with
`new-tab --layout-string` (plus `default_tab_template`, so the tab bar comes
along). Toggling a tab off also slashdashes it (`/-tab name=...`) in the file so
zellij skips it on the next fresh build; toggling on removes the marker. A
slashdashed tab is still defined: `ztab --list` shows it and `ztab <tab>`
brings it back. `--list` flags tabs whose open state disagrees with the file.
Edit the file by hand freely; changes apply to the next `zstop` + `zstart`, or
to a tab the next time it is opened.

## Customizing

Settings live in `${XDG_CONFIG_HOME:-$HOME/.config}/zellij-claude-workspace/config`
(zsh, see `examples/config`). An environment variable already set wins over the file.

| Variable | Default | Meaning |
| --- | --- | --- |
| `ZCW_SESSION` | `main` | the workspace session name |
| `ZCW_LAYOUT` | `~/.config/zellij/layouts/claude.kdl` | layout file ztab edits |
| `ZCW_PROJECT_DIRS` | none (zsh array) | where `ztab --create <name>` looks for `<dir>/<name>` |
| `ZCW_TAB_TEMPLATE` | `tab.kdl` in the config dir if present, else `share/tab.kdl` | tab template |

The tab template (`share/tab.kdl`) is one KDL tab block at the same 4-space
indent as in the layout, with `{{name}}` and `{{cwd}}` placeholders. Copy it to
the config dir and change the pane arrangement or the role names to taste;
`ztab --reconfigure` then brings existing tabs in line.

## Caveats

- `claude_create_or_resume` reads Claude Code's on-disk transcripts (`~/.claude/projects/<slug>/*.jsonl`, `custom-title` records), an undocumented internal format that may change; `claude_list_sessions` likewise reads `~/.claude/sessions`.
- A bare `zellij` spawns a stray server that rebuilds the whole layout and resumes every named session a second time. Use `zstart`; `zstop --strays` cleans up.
- Closing a tab kills its panes. Claude sessions resume when it reopens; the shell pane's scrollback is gone.
- A turn in flight when a pane is killed is lost; let panes go idle first.

## License

MIT
