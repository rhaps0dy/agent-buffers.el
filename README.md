# Agent Buffers (`agent-buffers.el`)

Open CLI coding agents (Claude Code, Codex, Gemini CLI, opencode, ...) per
project in an Emacs terminal buffer, plus a compose buffer for writing
messages to them without fighting the TUI.

A minimal alternative to
[claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el): no
WebSocket IDE protocol, no ediff permission prompts, no MCP tools server. The
harness can still reach Emacs via `emacsclient`.

## Files

- `agent-buffers.el` — sessions: start/toggle/stop a harness terminal per
  `(project, harness)` pair, in vterm / eat / ghostel.
- `agent-buffers-compose.el` — a markdown compose buffer per project;
  `C-c C-c` sends via bracketed paste. Snippet senders
  (`...-send-region/-defun/-buffer`) work from any buffer. Messages are
  archived per project and can be re-inserted (`C-c C-y`).
- `agent-buffers-jj.el` — `agent-buffers-workspace-create` makes a jj workspace
  under `agent-buffers-workspaces-base` (layout `BASE/REPO/NAME`; base revision
  is the changeset at point in majutsu buffers, else `@`) and starts a
  harness in it.
- `agent-buffers-sessions.el` — parses each CLI's on-disk session store so
  `agent-buffers-resume` can offer this project's past sessions (title +
  time since last use) in a completing-read picker instead of the CLI's
  own TUI picker.

All commands live in `agent-buffers-command-map`, meant to be bound under a
prefix (e.g. the Doom leader's `a`, and `C-c a` inside ghostel terminals).

## Harness profiles

A profile in `agent-buffers-harnesses` pins one model on one CLI:

```elisp
(claude-fable-5
 :command "claude --model claude-fable-5"
 :extra-flags "--permission-mode auto")
```

Traits of the CLI *program* rather than of the pinned model — the
continue/resume flags, the context-injection flag, the session-store
parser — live once per program in `agent-buffers-programs`, keyed by the
command's argv[0]:

```elisp
("claude"
 :continue-flag "--continue"
 :resume-flag "--resume"
 :system-prompt-flag "--append-system-prompt"
 :sessions-function agent-buffers-sessions-claude)
```

A profile plist may set any of those keys to override its program's
value. Several profiles can share a program (multiple opencode profiles
for different OSS models, one `claude` profile per model) — sessions
are keyed by `(project . profile-name)`, so such profiles run side by
side in one project. The profile name is used verbatim in completion
prompts and buffer names.

The default value ships example profiles, one per (CLI harness, model)
pair: Claude Code (`claude-fable-5`, `claude-opus-4-8`), Codex
(`gpt-5.6-sol`, `gpt-5.6-terra`), Gemini CLI (`gemini-3.5-flash`) and
opencode (`glm-5.2`); append your own models rather than restating
these. Profiles are deliberately named by the model's **API slug**, and
`:command` pins that same slug: the exact model identity stays visible
in the prompt and in buffer names, and can't silently change generation
when a vendor moves an alias. The cost is that entries go stale as
models are retired — moving to a new model is a deliberate edit, which
is the point.

Referring to a harness that is not in `agent-buffers-harnesses` (say, a stale
`agent-buffers-default-harness` after renaming a profile) signals an `error`
naming the configured profiles — a real `error`, not a `user-error`, so it
shows up under `debug-on-error`.

### Continue vs. resume

| | continue | resume |
|---|---|---|
| meaning | reopen the **most recent** session in this directory, no questions asked | pick among **past sessions** in this directory |
| Claude Code | `claude -c` / `--continue` | `claude -r` / `--resume [id]` |
| Codex | `codex resume --last` | `codex resume [id]` |
| Gemini CLI | — (use `/chat` inside the TUI) | — |
| opencode | `opencode --continue` | `opencode --session <id>` (no picker) |

The example profiles pin models on the command line, so e.g. continue
expands to `claude --model claude-fable-5 --continue`.

Codex's are subcommands, not flags; they work because the continue/resume
string is placed immediately after `:command`.

### The resume picker

`agent-buffers-resume` first tries to parse the CLI's own session store
via the program's `:sessions-function` (see `agent-buffers-sessions.el`)
and offers this directory's past sessions — `AGE TITLE` — through
ivy/completing-read, then resumes the chosen one by id. When the store
can't be parsed (no parser, or no sessions here) it falls back to
launching the CLI with the bare resume flag, i.e. the CLI's own TUI
picker. Store formats:

| CLI | store | id / title source |
|---|---|---|
| Claude Code | `~/.claude/projects/<munged-cwd>/<id>.jsonl` | filename; summary record or first user prompt |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | `session_meta` first line (filtered by its `cwd`); first `user_message` event |
| opencode | `$XDG_DATA_HOME/opencode/opencode.db` (SQLite) | `session` table: `id`, `title`, `directory`, `time_updated` |

## Buffer naming

Sessions are named `*profile-name[repo/workspace]*`. *workspace* is the
working-copy directory and *repo* the backing repository, so sibling
workspaces of one repo don't collide. Both jujutsu workspaces (`.jj/repo`)
and git worktrees (`.git` pointer file) are detected; in a colocated repo,
jujutsu wins. Plain directories (or the primary checkout) collapse to just
the directory name.

## Selection UI

Harness, session, project-file and history selection go through `ivy-read`
when ivy is available, falling back to `completing-read`.
