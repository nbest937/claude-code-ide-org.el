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
  Also trigger BEFORE writing any helper that touches org's own data —
  resolving or expanding an :ID:, finding archive files, listing agenda
  files, summing clocks, walking or sorting a datetree, following
  links, deriving a file path from #+ARCHIVE: — because org very often
  already provides it and the hand-rolled version is where the gaps
  live. Section 0b names where to look and what it cost the eight times
  this was skipped in one day.
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

### Never invoke bare `emacs` for a batch check — use `command emacs`

This is the one command that lies about section 0 by construction. The
user's shell profile defines:

```sh
emacs () {
  if [[ "$*" == *-nw* ]]; then command emacs "$@"
  else open -a Emacs --args "$@"; fi
}
```

and Claude Code's own shell snapshots carry it into every Bash tool call.
So `emacs --batch -Q --eval '...'` **does not run a batch Emacs at all**:
it hands the arguments to the running GUI app, which steals focus from
whatever the user is doing, and returns exit 0 with no stdout and no
stderr. That is indistinguishable from a batch run that completed and
found nothing wrong — so `check-parens`, a byte-compile, or an `--eval`
probe all report success without ever having executed.

Always:

```sh
command emacs --batch -Q -l ... -f ...      # or /opt/homebrew/bin/emacs
```

**`bin/test` is unaffected.** A `#!/usr/bin/env bash` script gets a
non-interactive shell where the function is not defined, so its `exec
emacs` resolves to the real binary. The trap is specific to inline
one-off verification — which is exactly the kind of check this skill
exists for.

Two tells that you have just been bitten: an Emacs window taking focus,
and a command that printed *nothing at all* when your own `--eval` ended
in a `message`. Treat a silent success from `emacs --batch` as a failed
check, not a passed one. Recorded as TODO.org `:ID: 4f9e552a`, where it
is logged as having been hit three times in a row before anyone noticed,
and twice more on 2026-08-14.

---

## 0b. Standing rule: check whether org already has it

**Before writing a helper that walks org files, resolves ids, derives
paths, or sorts a tree — look for org's own.** This repo has a measured
habit of rebuilding org machinery *beside* org rather than on it, and the
rebuilt version is where the gaps live: it is written against one
project's file list, one id shape, one assumption, and it inherits none
of org's twenty years of edge cases.

**On 2026-08-27 this happened eight times in one session**, which is how
the rule got written:

| built or asserted | org already had |
|---|---|
| `--archive-files-of`, ~35 lines reading `#+ARCHIVE:` | `org-add-archive-files` |
| `--known-id-table`, rebuilt per call | `org-id-locations` — 23,000x faster, archive-aware |
| "DONE.org can't be reached" | `org-id-search-archives`, default `t` |
| a re-sort pass for a newest-first datetree | `org-datetree-find-create-hierarchy` + `org-datetree-comparefun-from-regex` |
| plans to hand-order the archive | `org-archive-reversed-order` |
| ":CATEGORY: has a hard 12-char limit" | the manual says **10**, as *advice*; 12 is a `defcustom` default |
| "12 columns is a constraint" | `org-agenda-prefix-format`, user-settable |
| "finished work has no place in an agenda" | the manual says so, in "Archiving" |

Three of those were *asserted as fact without checking* and happened to
be right, which is worse than being wrong: it produces confident prose
that no one re-examines.

### Where to look, in order

1. **The tracker first.** `:ID:` 0465c1d5 had named
   `agenda-with-archives` and `file-with-archives` — and diagnosed the
   missing DONE.org symlink — *a month before* the same ground was
   re-covered from scratch. `org_query` and a scoped `org_outline` cost
   seconds. A past session may have already done the reading.
2. **The running Emacs**, which is authoritative over any documentation:
   ```
   emacsclient -e '(apropos-internal "org-.*archive.*file" (quote fboundp))'
   emacsclient -e '(documentation (quote org-add-archive-files))'
   emacsclient -e '(find-library-name "org-id")'
   ```
3. **The straight checkout**, for source and manual:
   ```
   ~/.config/emacs/.local/straight/repos/org/lisp/       # org-id.el, org-archive.el, org-datetree.el …
   ~/.config/emacs/.local/straight/repos/org/doc/org-manual.org
   ~/.config/emacs/.local/straight/repos/org/etc/ORG-NEWS # when a feature landed, and why
   ```
   `ORG-NEWS` earns its place: it answered "is this coming in a future
   release?" with "it shipped in 9.8, for a different reason."

### The test that decides it

**Does org track this already?** Org indexes ids, file locations, archive
targets, agenda files, clock sums. It does *not* index a heading's
keyword-and-title by id, which is why
`claude-code-ide-org--slice-referent-index` legitimately scans files and
`--known-id-table` did not.

When you do keep a local version, **say in its docstring which org
facility it duplicates and why** — the way
`claude-code-ide-org--id-scannable-files` records that it wraps
`org-add-archive-files` purely to undo that function's buffer side
effects. A divergence with a stated reason is a decision; one without is
an accident waiting to be re-made.

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

The concrete example this project hit, and which this skill now owns
outright: `org-clock-persist-load`/`org-clock-load` used
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

### Deleting a function needs more than a reload

`load-file` evaluates what is *in* a file. It does not unbind what you
removed *from* it. A deleted `defun` stays live in the running image
indefinitely, and — worse — anything still holding a reference keeps
working, so the reload looks clean and the suite passes because batch
loads a fresh Emacs each time.

Retiring a function therefore takes two steps:

```
emacsclient -e '(load-file "modules/tools/claude-code-ide-org/config.el")'
emacsclient -e '(fmakunbound (quote claude-code-ide-org--the-deleted-one))'
```

Then confirm the *callers* changed too, not just that the symbol is gone
— a caller's old definition is still resident until the reload replaces
it:

```
emacsclient -e '(string-match-p "the-deleted-one" (prin1-to-string (symbol-function (quote claude-code-ide-org-some-caller))))'
```

Expect `nil`. Note this matches docstrings as well as code, so a
docstring that *mentions* the retired function will return a position and
look like a failure — check what matched before believing it.

This is not hypothetical. On 2026-08-11 the `:SESSIONS:` drawer was
retired: every writer deleted, all 49 drawers removed from the org files,
suite green. Minutes later a clock-out recreated one, because `config.el`
had been edited on disk but never reloaded, so the live Emacs was still
running the old writer. The count caught it; nothing else would have.
Section 0's rule is the general form — this is the specific trap it
catches most often here.

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

## 7. What is in the Doom config, and why

Moved here from CLAUDE.md 2026-08-14: it is setup reference consulted when
changing these files, which is exactly this skill's trigger, not something
every session needs in context.

**Read the live file, not this summary, before acting on it.** The version
CLAUDE.md carried had drifted — it showed `(add-hook 'kill-emacs-hook
#'org-clock-out)` when the config actually uses a guarded wrapper. What
follows was verified against `~/.config/doom/config.el` and the running
Emacs on 2026-08-14.

```elisp
;; server.el must be required explicitly: server-running-p isn't
;; autoloaded (server-start is), so a fresh startup errors void-function
;; without this. The guard keeps a mid-session reload from hitting
;; server-start's "already running" prompt.
(require 'server)
(unless (server-running-p) (server-start))

(after! org
  (setq org-todo-keywords
        '((sequence "TODO" "NEXT" "PLANNING" "DOING" "WAITING" "MAYBE" "|" "DONE" "CANCELLED")))
  (setq org-clock-out-when-done t)
  (setq org-clock-persist 'history)
  (setq org-archive-location "DONE.org::* Done")
  ;; Doom's default is (list org-directory) and org expands it
  ;; non-recursively, so a file one level down never resolves. One-time
  ;; scan at load: a newly symlinked .org needs a restart to be seen.
  (setq org-agenda-files (directory-files-recursively org-directory "\\.org$"))
  (require 'org-depend))

;; org-clock-out has no guard and signals (user-error "No active clock"),
;; which these hooks would hit on every quit where nothing is clocked --
;; the common case. Hence the wrapper.
(defun claude-code-ide-org--clock-out-if-clocking ()
  (when (org-clocking-p) (org-clock-out)))
(add-hook 'kill-emacs-hook #'claude-code-ide-org--clock-out-if-clocking)
(add-hook 'suspend-hook    #'claude-code-ide-org--clock-out-if-clocking)

(use-package! claude-code-ide
  :config
  (setq claude-code-ide-mcp-server-port 45571)
  (claude-code-ide-emacs-tools-setup)
  (setq claude-code-ide-terminal-backend 'vterm)
  (global-auto-revert-mode 1))
```

Declared in `~/.config/doom/packages.el`:

```elisp
(package! claude-code-ide
  :recipe (:host github :repo "manzaltu/claude-code-ide.el"))
```

**`org-depend` is required, so `:BLOCKER:` is actually enforced.** Verified
live: `org-blocker-hook` holds `org-depend-block-todo` alongside this
project's own `claude-code-ide-org--blocker-clock-running-p`. The project's
function blocks on a running clock; org-depend's blocks on unsatisfied
`:BLOCKER:` IDs. Two different guards, both live — don't assume a refused
`DONE` came from the project's one.

**Known gap: `org-todo-keywords` has no `REVIEW`.** The sequence above
predates it, so `REVIEW` resolves only in files carrying their own
`#+TODO:` header line — TODO.org does, which is why it works there. A file
without one will not accept it.

**vterm**: requires the `:term vterm` Doom module (in `init.el`). Its
native module is compiled with cmake against homebrew `libvterm` — the
bundled build needs GNU libtool, which is not installed. The resulting
`vterm-module.so` lives in the straight repo dir, symlinked into the
straight build dir.

The live config also wires standalone Warp/CLI access (HTTP tools-server
session registration plus IDE-companion autostart, backing `.mcp.json`).
That is general claude-code-ide infrastructure rather than org-specific.

Only relevant with two Emacs.app processes at once: the second
`server-start` hits the "already running" prompt, since both claim the
default socket name.
