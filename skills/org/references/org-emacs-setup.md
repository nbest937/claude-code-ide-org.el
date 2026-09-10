# Emacs integration and install

> Ships with the **claude-code-ide-org** plugin as setup guidance — read
> once when wiring a machine or a new repo. Deliberately *not* promoted
> into `.claude/rules/` by `claude-org-setup`: it is consulted at install
> time, not needed in every session's context.

**A reachable Emacs server is a hard prerequisite, not a convenience** —
every MCP tool in this plugin goes through `emacsclient`. The Doom config
starts one automatically; if tools fail, check that first.

## One-time machine setup: the Doom module

The elisp half of the machinery is a Doom Emacs module, not something the
plugin can install — but the setup command prints exactly what your
`init.el` needs (print-only; the file is yours):

```sh
bin/claude-org-setup --doom
```

That emits an `(add-to-list 'doom-module-load-path ".../modules")` line
for before the `doom!` block plus the `:tools claude-code-ide-org` flag,
and refuses from an update-managed plugin copy (a load path into one
breaks on every update — run it from a clone). No symlink is needed:
Doom searches extra module-tree roots directly. (`doom-module-load-path`
is marked deprecated-for-v3 in Doom's source; re-verify at a Doom
upgrade. The old equivalent — symlinking
`modules/tools/claude-code-ide-org` into `~/.config/doom/modules/tools/`
— still works and is version-proof.)

- The module's `packages.el` declares **all of its dependencies
  itself** — `claude-code-ide` and org, both pinned, plus `org-ql` —
  so your root `packages.el` needs no entry (since 2026-09-10, `:ID:`
  e3caa21f). Doom merges duplicate `package!` declarations key-by-key
  with your private one processed last, so an existing root
  declaration is harmless: your keys win, the module's fill the gaps.
- The module needs **org 9.7+** and says so loudly at load — the org
  bundled with Emacs 29 (9.6.x) is not enough; Doom's straight-managed
  org is.
- **The module owns the standalone wiring** (since 2026-09-09,
  `:ID:` e396f94a), and since 2026-09-10 the config lives in a
  *generated* file (`:ID:` 7c86ab4c):

  ```sh
  claude-org-setup --glue
  ```

  writes `$DOOMDIR/claude-code-ide-org-glue.el` (marker-headed,
  refreshed by re-run, never yours to edit) and prints the one stable
  stub for your `config.el`:

  ```elisp
  (load! "claude-code-ide-org-glue" doom-user-dir t)
  ```

  The glue defers itself until `claude-code-ide` loads and derives the
  project list from the tracked files at every wire call — onboarding
  a repo is making its org files discoverable plus
  `M-x claude-code-ide-org-standalone-wire`, no elisp edit anywhere.
  The wire pins the port (`claude-code-ide-org-standalone-port`, default
  `45571`, checked **loudly** against what the shipped `.mcp.json`
  actually names), starts the tools server, and registers a session
  per listed project — each under its directory basename, the first
  also as `warp`, the session id the shipped `/mcp/warp` URL names.
  The port stays pinned by design: the static `.mcp.json` is the
  contract every client reads, and a dynamic port would need
  discovery machinery that standalone clients do not have.
- Tracked-file discovery: the tools operate on
  `claude-code-ide-org-query-files`, falling back to
  `org-agenda-files`. A repo's org files must be inside that universe
  or every `:ID:`-scoped operation fails to find them. **Keep
  `org-agenda-files` as org's agenda list file** — set the variable to
  a single file *name* (e.g. `~/org/agenda-files`, one tracked path
  per line, `~` fine) and org re-reads it on every access, so
  discovery is dynamic: append a line and the next tool call sees it,
  no symlink, no restart, and `claude-org-setup --org` appends the
  lines itself. A config that instead computes a list at load (a
  directory scan, a hand-kept `list`) freezes discovery at that
  moment, and every newly added file then waits for a restart.

## Per-repo setup: a consuming repo

1. **Enable the plugin.** Per session: `claude --plugin-dir
   /path/to/claude-code-ide-org`. **Enable once instead** (`:ID:`
   7dbb82e0, against Claude Code's docs 2026-09-10): symlink the clone
   into the skills directory —

   ```sh
   ln -s /path/to/claude-code-ide-org ~/.claude/skills/claude-code-ide-org
   ```

   — and every session in every project auto-loads it as
   `claude-code-ide-org@skills-dir`: referenced in place (a `git pull`
   or local edit is live next session), `bin/` permitted, one-time
   trust prompt per project. Either way, enabling is the consent that
   brings the hooks, the MCP server, the org skill and `bin/` onto
   `PATH`.

   **Mandatory companion step for the plugin's own repo**: user-wide
   auto-load includes the `claude-code-ide-org` clone itself, whose
   `.claude/settings.json` wires the same hooks — both active means
   every queue event appended twice. Disable the plugin there, in the
   clone's `.claude/settings.local.json`:

   ```json
   { "enabledPlugins": { "claude-code-ide-org@skills-dir": false } }
   ```

   (A local marketplace via `extraKnownMarketplaces` +
   `/plugin install` is the per-project-controlled alternative; the
   docs are ambiguous on whether a local-marketplace install
   references the clone or copies it to a cache, so the skills-dir
   route is the one this project recommends. The old belief that
   "marketplace forbids `bin/`" is false in general — `bin/` is
   refused only for plugins force-distributed through managed
   organization settings.)
2. **Run `claude-org-setup` in the repo root.** It copies the convention
   and machinery rules from the plugin's skill references into the
   repo's `.claude/rules/`, so they load in every session rather than
   only when someone thinks to read a reference. Re-run it after a
   plugin update to refresh the copies.
3. **Scaffold and discover the repo's org files**:

   ```sh
   claude-org-setup --org
   ```

   creates `TODO.org` and `DONE.org` from the shipped templates
   (collision-checked; an existing file is reported, never touched).
   With an agenda list file in place (`~/org/agenda-files`, or
   `CLAUDE_ORG_AGENDA_LIST`) it **appends the new paths itself** —
   discovery is immediate, and the only follow-up is a wire call (or
   the next Emacs start). Without one it prints the legacy follow-ups
   — `~/org` symlinks and a restart or `add-to-list`. Once
   discoverable, targetless `org_capture` calls from this project's
   sessions land in its own tracker automatically.

Two behaviours worth knowing before they surprise you:

- **Do not enable the plugin's hooks in a repo that already wires the
  same scripts through its own `.claude/settings.json`** — the
  `claude-code-ide-org` repo itself is the standing example — or every
  guidepost and queue event is appended twice.
- **`doc-sync-check` fires on any `CLAUDE.md` or `README.md` edit** and
  reminds the session that the two share a hand-synced overlap zone.
  That convention is this plugin's home repo's; in a repo that does not
  keep the two in sync the reminder is noise you can ignore (or drop
  the hook by disabling the plugin's hooks for that repo).

## The rest of the Doom config

The org settings, the clock-out hooks, the `claude-code-ide` block,
vterm's build quirk, and which guards are live on `org-blocker-hook` are
documented in the **org-dev skill** in the `claude-code-ide-org` repo,
which triggers precisely when you are changing those files. Read the
live `~/.config/doom/config.el` rather than any summary of it; summaries
of it have drifted before.
