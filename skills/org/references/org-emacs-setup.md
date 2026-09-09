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

- The module needs **org 9.7+** and says so loudly at load — the org
  bundled with Emacs 29 (9.6.x) is not enough; Doom's straight-managed
  org is.
- **The module owns the standalone wiring** (since 2026-09-09,
  `:ID:` e396f94a). In your Doom config, after the module loads:

  ```elisp
  (setq claude-code-ide-org-standalone-projects
        '("~/git/claude-code-ide-org"))   ; the repos to serve
  (claude-code-ide-org-standalone-wire)
  ```

  That pins the port (`claude-code-ide-org-standalone-port`, default
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
  or every `:ID:`-scoped operation fails to find them — and
  `org-agenda-files` is computed once at config load, so a newly added
  file needs an Emacs restart to be seen.

## Per-repo setup: a consuming repo

1. **Enable the plugin** (`claude --plugin-dir /path/to/claude-code-ide-org`,
   or an installed copy). Enabling it is the consent that brings the
   hooks, the MCP server, the org skill and `bin/` onto `PATH`.
2. **Run `claude-org-setup` in the repo root.** It copies the convention
   and machinery rules from the plugin's skill references into the
   repo's `.claude/rules/`, so they load in every session rather than
   only when someone thinks to read a reference. Re-run it after a
   plugin update to refresh the copies.
3. **Make the repo's org files discoverable** (previous section) and
   give each one the file header the conventions specify.

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
