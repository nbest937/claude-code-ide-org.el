---
name: org-dev
description: >
  Use this skill when changing this repo's own code — config.el,
  config-test.el, bin/test, the org/org-dev skills themselves, or the
  claude-code-ide-related parts of the user's Doom config
  (~/.config/doom/config.el, ~/.config/doom/init.el,
  ~/.config/doom/packages.el) — and verifying
  the change actually took effect. Different from the org skill: that
  one edits .org file *content* for end users; this one reloads and
  verifies changes to *this project's own tooling*. Trigger on explicit
  requests ("reload", "verify this works", "test in Emacs", "did that
  take effect") and proactively whenever config.el, config-test.el, or
  the Doom config has just been edited in this session — don't wait to
  be asked before checking that a code change actually loaded.
---

# org-dev — Reload & Verify Skill

This skill covers the mechanics of getting a change to this repo's own
Elisp (or its Doom wiring) actually live in a running Emacs, and proving
it — not just claiming a tool call succeeded. It exists because this
repo's own development sessions kept re-discovering the same handful of
gotchas by hand.

---

## 0. Standing rule: say what needs reloading, before you check

Before running any command whose purpose is "see whether that change took
effect," state in one line what has to be reloaded or restarted first —
or that nothing does. For example: "no reload needed, hook scripts are
read fresh from disk on every invocation"; "this needs
`emacsclient -e '(load-file ...)'` first"; "this needs a brand-new Claude
Code session, since hook config is only read at session start."

This project is the reason the rule exists. Verification here spans four
layers with genuinely different reload semantics — Elisp in a live Emacs,
MCP tool registration, Claude Code hook configuration, and shell scripts —
and a check run against a stale layer is indistinguishable from a passing
one. Sections 1 and 2 below are the mechanics; this is the habit that
makes them count.

The general form of this rule (it is not specific to Emacs, or to this
repo) lives in `~/.claude/CLAUDE.md`. It is restated here because this
project's own contributors are the ones most likely to need it, and a
skill should not depend on a personal config file existing.

---

## 1. Live reload procedure

For a change confined to function bodies inside
`modules/tools/claude-code-ide-org/config.el` (existing `defun`s, or the
`claude-code-ide-make-tool` registrations inside the single
`with-eval-after-load 'claude-code-ide` block, which is the last
top-level form in the file), a live reload is enough — no restart
needed:

```
emacsclient -e '(load-file "modules/tools/claude-code-ide-org/config.el")'
```

Run this with the shell's cwd at the repo root, or pass an absolute path
— `emacsclient -e` evaluates relative to Emacs's current
`default-directory`, not the shell's, so a bare relative path can
silently resolve against the wrong buffer's directory.

`config.el`'s tool registrations live inside a single
`with-eval-after-load 'claude-code-ide` block. In a normal running Doom
session `claude-code-ide` is already loaded, so `with-eval-after-load`
fires **immediately** when you re-evaluate the file — that's why a live
reload is sufficient here, without needing to trigger `claude-code-ide`'s
own load sequence again.

## 2. When live reload isn't enough — full restart required

Live reload only re-runs code in an *already-running* Emacs. It cannot
simulate a fresh boot's package-load ordering. Anything whose correctness
depends on *when*, relative to other packages loading, a hook or
`after!`/`with-eval-after-load` block first fires needs a full Emacs
restart to actually verify — reloading the already-running instance will
look fine and tell you nothing about first-boot behavior.

The concrete example this project hit (see CLAUDE.md's "Design notes",
`org-clock-load` entry): `org-clock-persist-load`/`org-clock-load` used
to need an explicit call after `(setq org-clock-persist ...)`. Newer
`org.el` registers it on `org-mode-hook` itself, so calling it explicitly
inside `(after! org ...)` in the Doom config is not just redundant but
breaks org-mode outright — `after!` fires the instant `org.el` calls
`(provide 'org)`, which happens *before* `org-clock.el` (home of that
function) has loaded, producing a void-function error. This only shows
up on a *fresh* Emacs startup, because that's the only time `org.el`'s
own load sequence actually runs top to bottom — a `load-file` reload of
a session where `org` is already provided never re-triggers it. Don't
add that call back to the Doom config.

**Rule of thumb:** if the change touches `after!`, `with-eval-after-load`,
`:hook`, `add-hook`, or any `package!`/`use-package!` declaration in
`~/.config/doom/{config,init,packages}.el`, verify with a real restart,
not just a live reload.

## 3. Post-restart re-verification

After a restart, the Warp-wiring block in the Doom config
(`claude-code-ide-org--wire-warp-tools`) re-runs automatically at
startup — don't call it by hand. Instead confirm it actually came back
up. Note the wiring starts *two separate things*, and only one of them
writes a lockfile — don't conflate them.

**MCP server port** (pinned to `45571` in this user's Doom config,
matching `.mcp.json`'s `http://localhost:45571/mcp/warp`):

```
emacsclient -e '(claude-code-ide-mcp-server-get-port)'
```

Expect `45571`. `nil` means the wiring block didn't run or failed — that's
a signal to go investigate the Doom config, not to manually call
`claude-code-ide-mcp-server-ensure-server` as a workaround; that function
starts the server as a side effect and calling it by hand papers over
whatever the startup wiring should have done itself. This pinned HTTP
tools-server (`claude-code-ide-mcp-server.el`) never writes a lockfile of
its own — don't go looking for one at `~/.claude/ide/45571.lock`, it will
never exist under that name.

**IDE-companion lockfile** — written by upstream `claude-code-ide`'s
`claude-code-ide-mcp-start` (a *separate* WebSocket companion server,
distinct from the pinned HTTP tools-server above) at
`~/.claude/ide/<port>.lock`. That `<port>` is chosen at random from
`claude-code-ide-mcp-port-range` (10000–65535, see
`claude-code-ide-mcp.el`) every time it starts, so it will **not** match
the pinned `45571` — checking for `45571.lock` specifically will always
fail and tells you nothing. Since the port isn't predictable, match on
PID and workspace instead:

```
for f in ~/.claude/ide/*.lock; do echo "== $f =="; cat "$f"; echo; done
emacsclient -e '(emacs-pid)'
```

Expect one lockfile whose `pid` equals the running Emacs process's PID,
with `workspaceFolders` containing this repo's path, `ideName: "Emacs"`,
`transport: "ws"`. No entry with a matching PID is a partial-wiring state
worth flagging; an entry whose PID does *not* match the current Emacs
process is a stale lockfile left behind by a previous (crashed or
uncleanly killed) Emacs process, not evidence about the current one.

**Warp session reachability** — the most direct evidence the `"warp"`
session actually registered is that an `org_*` MCP tool call over the
`.mcp.json`-configured `emacs-tools` server succeeds. A connection error
there means check the port above (and the PID-matched lockfile) before
assuming the tool itself is broken.

## 4. Sanity-check pattern after any reload

Before trusting that a newly added or renamed function is live, check
for it directly rather than inferring success from "the reload command
didn't error":

```
emacsclient -e '(fboundp (quote claude-code-ide-org-newly-added-function))'
```

This is a quick ad hoc ping for a live Emacs instance, not a substitute
for `bin/test` — `bin/test` verifies wrapper-function *behavior* (see
`config-test.el`'s fixture-based tests, which assert on-disk contents,
not just in-memory results); `fboundp` only tells you the symbol exists
in the running session.

## 5. The Claude-Code-hook-side limit

Editing `.claude/settings.json` (the `Stop`/`UserPromptSubmit`/
`SessionStart` hook wiring) never takes effect in the *current* Claude
Code session — hook configuration is read once at session start. This
skill can only detect the edit and tell the user a new session is
needed; nothing running inside a session can force that same session to
restart. Don't imply a hook change is live until a new session has
actually started.

## 6. Troubleshooting: `bin/test` org-version pinning

If a function seems unexpectedly void, or a test fails in a way that
doesn't match what the code visibly does, confirm `bin/test` is loading
the *straight-managed* org, not Emacs's bundled one.

`emacs --batch -Q` on its own loads Emacs's bundled org (e.g. 9.6.15 on
this machine) instead of the straight-managed checkout Doom actually
uses (e.g. 9.8.7) — a real version gap that once caused
`org-element-type-p` (only present in the newer org) to be silently
unavailable during tests. `bin/test` (`bin/test:8-20`) works around this
by globbing for a `build-*` directory under
`~/.config/emacs/.local/straight` and prepending its `org` subdirectory
to `load-path` before loading `config.el`:

```
org_build_dir="$(find "$HOME/.config/emacs/.local/straight" -maxdepth 1 -name 'build-*' -type d | head -1)/org"
```

If that glob ever matches nothing (e.g. a fresh straight checkout that
hasn't built yet), `bin/test` silently falls back to the bundled org
again with no error — the symptom is tests behaving as if a newer
org-mode feature doesn't exist. Check `ls ~/.config/emacs/.local/straight/build-*/org` if that happens.
