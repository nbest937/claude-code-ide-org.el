# The Doom sandbox: reviewing the packaging as a second user

Proper review of the plugin's install story needs two perspectives this
repo's own working setup cannot provide: a **new project** consuming the
plugin, and a **fresh user** wiring the Doom module from nothing. The
second looks like it needs another account; it does not. Doom relocates
its entire private state through two environment variables, so a
"second user" is just a shell where both point somewhere fresh under
your own `$HOME` — a virtual environment for a Doom profile, no
privileges required. This file is the procedure, with the collisions
you will hit named in advance.

Everything here was verified against the live checkout (Doom v2.2.0
master): `doom.el` reads `DOOMDIR` (the private config) and
`DOOMLOCALDIR` (packages, builds, caches), and the newer
`DOOMPROFILE`/`profiles.el` machinery exists but compiles down to the
same variables — the env-var route is the substrate, and simpler for a
one-off review.

## 1. Create the sandbox profile

```sh
export DOOMDIR=~/doom-sandbox/config
export DOOMLOCALDIR=~/doom-sandbox/local
mkdir -p "$DOOMDIR"
~/.config/emacs/bin/doom install   # seeds init.el / config.el / packages.el
```

Every later `doom sync` and Emacs launch for the sandbox must run in a
shell with these set — the variables *are* the profile.

## 2. Give the sandbox its own clone (this is also the port answer)

Clone the repo a second time for the sandbox:

```sh
git clone ~/git/claude-code-ide-org ~/doom-sandbox/claude-code-ide-org
```

A second clone is not pedantry — it is what resolves the one hard
collision. Only one MCP tools server can bind a port per machine, and
the module's wiring check refuses a pin that disagrees with what its
own clone's `.mcp.json` names, because that static file is the contract
every client reads. **The contract is per-clone.** So the sandbox gets
its own contract:

- edit the *sandbox clone's* `.mcp.json` (and `.warp/.mcp.json`) to a
  free port, e.g. `http://localhost:45572/mcp/warp` — a local working
  tree edit, never committed;
- set the matching pin in the sandbox `config.el` (step 4).

Both Emacsen can then run at once, each serving its own port, and the
loud pin-check passes on both sides — which is the guard working, not
being worked around: port and contract changed together.

## 3. Wire the sandbox's init.el and packages.el

From the sandbox clone:

```sh
~/doom-sandbox/claude-code-ide-org/bin/claude-org-setup --doom
```

It prints (never writes) the two `init.el` lines: the
`doom-module-load-path` entry for that clone's `modules/`, placed
*before* the `doom!` block, and the `claude-code-ide-org` flag under
`:tools`. Paste them into `$DOOMDIR/init.el`.

The sandbox `packages.el` needs the dependency the module cannot
declare for you:

```elisp
(package! claude-code-ide
  :recipe (:host github :repo "manzaltu/claude-code-ide.el"))
```

(The module's own `packages.el` brings `org-ql`; org 9.7+ arrives via
Doom's straight-managed org and the module refuses loudly at load if it
did not.)

## 4. Wire the sandbox's config.el

From the sandbox shell (its `DOOMDIR` is already exported), let the
setup command generate the wiring glue:

```sh
~/doom-sandbox/claude-code-ide-org/bin/claude-org-setup --glue
```

then the sandbox `config.el` needs only the port pin (the sandbox's
own contract from step 2) plus the printed stub:

```elisp
(use-package! claude-code-ide
  :config
  (setq claude-code-ide-org-standalone-port 45572)  ; match step 2's edit
  (load! "claude-code-ide-org-glue" doom-user-dir t))
```

The glue derives its project list from the sandbox's tracked files, so
the testbed registers itself once step 6 makes it discoverable.

Also give the sandbox Emacs a distinct server identity so
`emacsclient` calls cannot cross wires with your real session, and its
own org universe so testbed files never enter your real agenda:

```elisp
(setq server-name "doom-sandbox")
(setq org-directory "~/doom-sandbox/org")
```

## 5. Sync and launch — this is the fresh-machine experience

```sh
doom sync    # in the env-var shell; builds every package into DOOMLOCALDIR
emacs        # same shell
```

The first sync is slow because it is honest: a new user pays it too.
The org 9.7 floor check, the package graph, the module discovery
through `doom-module-load-path` — all exercised exactly as the shipped
instructions claim.

## 6. The consuming project, from the same sandbox

```sh
mkdir -p ~/doom-sandbox/testbed && cd ~/doom-sandbox/testbed
claude --plugin-dir ~/doom-sandbox/claude-code-ide-org
```

Inside that session the plugin's hooks, MCP server (port 45572, via
the sandbox clone's `.mcp.json`) and skill are live. Then, in the repo:

```sh
claude-org-setup            # promotes conventions + machinery rules
claude-org-setup --org      # scaffolds TODO.org/DONE.org from the templates
```

`--org` creates the org files (collision-checked — an existing file is
reported, never touched) and prints the discoverability follow-ups.
For the sandbox, point them at the *sandbox* universe: symlinks under
`~/doom-sandbox/org/testbed/` (the `org-directory` from step 4), and
the restart-or-`add-to-list` against the *sandbox* Emacs. Targetless
`org_capture` calls from testbed sessions then land in the testbed's
own TODO.org — the session-routed capture path, which is itself part
of what this review exercises, alongside the promoted rules governing
a repo with real org files of its own.

## Collisions and cautions, collected

- **Port**: solved structurally by the second clone (step 2). Without
  it, only one tools server binds 45571, and the pin-check refuses a
  mismatched pin by design.
- **Emacs server name**: set `server-name` in the sandbox (step 4).
- **Shared org files**: never let both Emacsen visit the same
  `TODO.org` — two live buffers over one file is the buffer/disk
  divergence the queue architecture exists to avoid. The sandbox
  reviews against its own testbed files.
- **Hooks double-fire**: does not arise here — the testbed project has
  no `.claude/settings.json` wiring of its own, so the plugin's
  `hooks/hooks.json` is the only copy running. (The rule stands for
  this repo itself: one wiring or the other, never both.)
- **Queue directory is shared**: `~/.claude/org-updates/` is user-level,
  so sandbox sessions append there too. Their events name testbed
  headings and the testbed `cwd`; the review pass will show them —
  which is itself part of the review.

## Teardown

```sh
rm -rf ~/doom-sandbox
unset DOOMDIR DOOMLOCALDIR
```

Nothing outside `~/doom-sandbox` and the shared queue directory was
touched; your real profile never knew.

## The tidier long-term shape

Doom's native profiles (`DOOMPROFILE` plus a `profiles.el` in
`~/.config/doom/` or `~/.config/emacs/`) name and persist exactly this
arrangement, switchable per launch. Worth adopting if sandbox reviews
become routine; for a one-off, the env vars above are fewer moving
parts.
