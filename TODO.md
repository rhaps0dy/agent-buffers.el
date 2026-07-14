# TODO

## jj integration (first priority)

- [x] `agent-buffers-workspace-create`: one command that creates a jj workspace
      (under `agent-buffers-workspaces-base`, default `~/Programacio/worktrees`,
      layout BASE/REPO/NAME) and starts an agent in it. Base rev: changeset
      at point in majutsu buffers, else current @. Bound at `SPC a w`.
      Bookmarks deliberately skipped for now (decision 2026-07-01: defer
      until the push workflow is clearer).
- [ ] Associate each jj changeset with the agents that worked on it
      (harness + session/context id), persisted somewhere queryable
      (changeset description trailer? a table keyed by change-id?).
      - probably a table, description trailer is bad for collaborating and doesn't transfer among different machines. I don't know how to easily query the session uuid/descriptor when starting a new workspace; perhaps checking in ~/.claude for the file that was just created? Best to deprioritize this whole feature (changeset<->agent association) until the rest is working.
- [ ] majutsu integration: from a changeset at point, one action =
      create workspace + resume that changeset's session in it, so any
      changeset can be "picked up" by its agent later.
- [ ] Agent names derive from the workspace name. Allow >1 agent per
      workspace (second one usually read-only/Q&A) with a name suffix,
      e.g. `*claude[repo/ws]*`, `*claude[repo/ws#2]*`.

## git integration (lower priority)

- [ ] Same as above with `git worktree add` + branch; commit↔session
      association via notes or trailers. Think about a shared abstraction
      with the jj path before building either.

## harness/config

- [ ] Add more opencode profiles (several, one per OSS model); figure out
      opencode's continue/resume story (`--session` needs an explicit id).
- [x] Session-id capture (reading direction): agent-buffers-sessions.el parses
      each CLI's store and `agent-buffers-resume` resumes a picked id.
- [ ] Session-id capture (writing direction): learn the id of a session *we
      started* (claude: newest file in the project dir? codex: newest
      rollout?) to associate it with a changeset. Needed for the
      changeset↔session feature.

## config.org / UX

- [x] Ghostel: leader (`SPC`) is swallowed by the terminal, must use `M-SPC`;
      make it possible to reach the `SPC a` map from a ghostel buffer.
      → done: `agent-buffers-command-map` is bound at `C-c a` in
      `ghostel-mode-map` (`C-c` is the one prefix semi-char mode lets
      through; `C-c <letter>` was free). `M-1`..`M-9` added to
      `ghostel-keymap-exceptions` so workspace switching works too.
      `SPC` itself must keep going to the terminal, so the leader proper
      stays `M-SPC`.
- [x] `agent-buffers-send-escape` / `-insert-newline` only target the default
      harness; make them use the session in the current buffer when called
      from one. (if project has multiple harnesses, default to last visited one but open an ivy pick)
      → done: `agent-buffers--current-session-buffer` (also used by compose).
- [ ] (not yet) Byte-compile / autoloads story if this becomes a standalone package.
