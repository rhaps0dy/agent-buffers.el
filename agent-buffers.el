;;; agent-buffers.el --- Open CLI coding harnesses per project  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Adrià Garriga-Alonso

;; Author: Adrià Garriga-Alonso <adria@theorem.dev>
;; Maintainer: Adrià Garriga-Alonso <adria@theorem.dev>
;; URL: https://github.com/rhaps0dy/agent-buffers.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (markdown-mode "2.6"))
;; Keywords: tools, processes, terminals

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; A minimal alternative to claude-code-ide.el: open and name a terminal
;; running an arbitrary CLI coding harness (Claude Code, Codex, Gemini CLI,
;; opencode, ...) in the current project, in a side window, and
;; toggle/reopen it later.
;;
;; What it deliberately does NOT do (unlike claude-code-ide):
;;   - no WebSocket IDE protocol (selection/buffer tracking, openDiff/ediff)
;;   - no per-edit ediff permission prompts
;;   - no MCP tools server (xref/imenu/project exposed to the harness)
;;
;; The harness can still run `emacsclient' as a subprocess (that needs only a
;; running Emacs server, `M-x server-start' / Doom's default daemon) -- it is
;; entirely independent of the machinery this package drops.
;;
;; Each harness is a profile in `agent-buffers-harnesses'.  Sessions are keyed by
;; (project-root . harness), so you can run Claude and Codex side by side in the
;; same project.
;;
;; Continue vs. resume:
;;   - "continue" reopens the MOST RECENT session for the working directory,
;;     without asking.  Claude Code: `-c' / `--continue'.
;;     Codex: `resume --last'.
;;   - "resume" opens the harness's interactive session PICKER (and usually
;;     also accepts an explicit session id on the command line).
;;     Claude Code: `-r' / `--resume [id]'.  Codex: `resume [id]'.
;;   For Codex these are subcommands rather than flags; they work here because
;;   `agent-buffers--build-command' places the continue/resume string immediately
;;   after :command, before anything else.
;;
;; Session buffers are named *HARNESS[repo/workspace]*.  "workspace" is the
;; working-copy directory name and "repo" the backing repository: we detect
;; jujutsu workspaces (via .jj/repo) and git worktrees (via the .git pointer
;; file); when both are present (a colocated repo) jujutsu wins.  Plain
;; directories, and primary checkouts where repo and workspace coincide, fall
;; back to the bare directory name.
;;
;; Usage:
;;   M-x agent-buffers            -- open/toggle the default harness for this project
;;   C-u M-x agent-buffers        -- pick a harness (via ivy when available)
;;   M-x agent-buffers-switch     -- switch to this project's last visited harness
;;   M-x agent-buffers-select     -- pick a harness, creating it if needed
;;   M-x agent-buffers-continue   -- open, continuing the latest session here
;;   M-x agent-buffers-resume     -- open the harness's session picker
;;   M-x agent-buffers-toggle     -- toggle the window
;;   M-x agent-buffers-stop       -- kill the session
;;   M-x agent-buffers-list-sessions
;;
;; See agent-buffers-compose.el for a companion compose buffer.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'subr-x)

;; External declarations for the optional terminal backends.
(defvar eat-terminal)
(defvar eat-term-name)
(defvar vterm-shell)
(defvar vterm-environment)
(defvar vterm-buffer-name)
(defvar ghostel-set-title-function)
(defvar ghostel-enable-title-tracking)
(defvar ghostel-kill-buffer-on-exit)
(declare-function vterm "vterm" (&optional arg))
(declare-function vterm-send-string "vterm" (string))
(declare-function vterm-send-escape "vterm" ())
(declare-function vterm-send-return "vterm" ())
(declare-function eat-mode "eat" ())
(declare-function eat-exec "eat" (buffer name command startfile &rest switches))
(declare-function eat-term-send-string "eat" (terminal string))
(declare-function ghostel-exec "ghostel" (buffer program &optional args))
(declare-function ghostel-send-string "ghostel" (string))
(declare-function ivy-read "ivy")

;;; Customization

(defgroup agent-buffers nil
  "Open CLI coding harnesses per project."
  :group 'tools
  :prefix "agent-buffers-")

(defcustom agent-buffers-harnesses
  ;; Profiles are named by the model's API slug by default (e.g.
  ;; `claude-fable-5'), and the commands are pinned to the same model.
  ;; These entries go stale as models are retired -- moving to a new
  ;; model is a deliberate edit, which is the point.
  '((claude-fable-5 :command "claude --model claude-fable-5")
    (claude-opus-4-8 :command "claude --model claude-opus-4-8")
    (gpt-5.6-sol :command "codex --model gpt-5.6-sol")
    (gpt-5.6-terra :command "codex --model gpt-5.6-terra")
    (gemini-3.5-flash :command "gemini --model gemini-3.5-flash")
    (glm-5.2 :command "opencode --model openrouter/z-ai/glm-5.2"))
  "Alist of harness profiles.

The default value is a set of examples, one per (CLI harness, model)
pair; append your own models rather than restating these.  Several
profiles can share a program -- the two claude entries differ only in
--model -- and `agent-buffers' keys sessions by (project . NAME), so
such profiles can run side by side in one project.

Each entry is (NAME . PROFILE).  NAME is a symbol, used verbatim in
completion prompts and buffer names.  PROFILE is either a command
string or a plist:

  :command      (string, required) the executable / command line.
  :extra-flags  (string) extra flags always appended.

Traits of the CLI program rather than of the pinned model -- the
continue/resume flags, context injection, session listing -- live in
`agent-buffers-programs', keyed by the command's program name.  A profile
plist may also set any of those keys to override its program's value."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'agent-buffers)

(defcustom agent-buffers-programs
  '(("claude"
     :continue-flag "--continue"
     :resume-flag "--resume"
     :system-prompt-flag "--append-system-prompt"
     :sessions-function agent-buffers-sessions-claude)
    ("codex"
     ;; `resume' is a codex subcommand, not a flag: `codex resume --last'
     ;; continues the latest session, `codex resume' opens the picker.  This
     ;; works because continue/resume strings go right after :command.
     :continue-flag "resume --last"
     :resume-flag "resume"
     :sessions-function agent-buffers-sessions-codex)
    ;; Gemini CLI has no entry: it has no continue/resume command-line
    ;; flags (sessions are managed with the /chat slash commands inside
    ;; the TUI), so continue/resume simply start a fresh session.
    ("opencode"
     :continue-flag "--continue"
     ;; `--session' wants an explicit session id rather than opening a
     ;; picker, so resume only works through our own session picker.
     :resume-flag "--session"
     :sessions-function agent-buffers-sessions-opencode))
  "Alist mapping a harness program to its CLI-level traits.
The key is the program name (argv[0], sans directory) of a profile's
:command.  These traits belong to the CLI program, not to the model a
profile pins, so they live here once per program and profiles stay
minimal.  Keys:

  :continue-flag      (string) appended for `agent-buffers-continue' --
                      reopen the latest session in this directory
                      without prompting.
  :resume-flag        (string) appended for `agent-buffers-resume' --
                      opens the CLI's interactive session picker, or,
                      followed by a session id, resumes that session.
  :system-prompt-flag (string) flag used to inject project context
                      (see `agent-buffers-context-directories').  Omit for
                      programs that have no such flag -- context is then
                      simply not injected.
  :sessions-function  (symbol) function taking a directory and returning
                      a list of (:id ID :title TITLE :time TIME) plists
                      for past sessions there; lets `agent-buffers-resume'
                      offer its own picker (see agent-buffers-sessions.el)."
  :type '(alist :key-type string :value-type plist)
  :group 'agent-buffers)

(defcustom agent-buffers-default-harness 'claude-fable-5
  "Harness used by `agent-buffers' when none is chosen interactively.
Must name an entry of `agent-buffers-harnesses'."
  :type 'symbol
  :group 'agent-buffers)

(defcustom agent-buffers-terminal-backend 'vterm
  "Terminal backend: `vterm', `eat', or `ghostel'."
  :type '(choice (const vterm) (const eat) (const ghostel))
  :group 'agent-buffers)

(defcustom agent-buffers-buffer-name-function #'agent-buffers--default-buffer-name
  "Function returning a buffer name, called with (DIRECTORY HARNESS)."
  :type 'function
  :group 'agent-buffers)

(defcustom agent-buffers-use-side-window t
  "When non-nil, show the harness in a dedicated side window.
When nil, show it in a normal window on `agent-buffers-window-side'
instead; unlike a side window, a normal window can be split further
\(e.g. \\[split-window-below])."
  :type 'boolean
  :group 'agent-buffers)

(defcustom agent-buffers-window-side 'right
  "Side of the frame for the harness window."
  :type '(choice (const left) (const right) (const top) (const bottom))
  :group 'agent-buffers)

(defcustom agent-buffers-window-width 100
  "Body width of the harness window when on the left or right."
  :type 'integer
  :group 'agent-buffers)

(defcustom agent-buffers-window-height 20
  "Height of the harness window when on the top or bottom."
  :type 'integer
  :group 'agent-buffers)

(defcustom agent-buffers-focus-on-open t
  "When non-nil, select the harness window when it opens."
  :type 'boolean
  :group 'agent-buffers)

(defcustom agent-buffers-context-directories
  '("~/.doom.d" "~/.config/emacs")
  "Directories whose projects get `agent-buffers-context-string' injected.
A session whose working directory is at or under one of these gets the
context string appended via the harness's :system-prompt-flag.  Set to nil
to never inject context."
  :type '(repeat directory)
  :group 'agent-buffers)

(defcustom agent-buffers-context-string
  "IMPORTANT: Connected to Emacs. Emacs uses mixed coordinates: Lines are 1-based (line 1 = first line), Columns are 0-based (column 0 = first column). You can run emacsclient to inspect and edit buffers."
  "Context appended for projects under `agent-buffers-context-directories'.
Set to nil to disable context injection entirely."
  :type '(choice (const :tag "None" nil) string)
  :group 'agent-buffers)

(defcustom agent-buffers-terminal-initialization-delay 0.1
  "Seconds to let the terminal settle before displaying it."
  :type 'number
  :group 'agent-buffers)

;;; State

(defvar agent-buffers--processes (make-hash-table :test 'equal)
  "Hash table mapping (ROOT . HARNESS) to the harness process.")

(defvar agent-buffers--last-accessed-buffer nil
  "Most recently displayed harness buffer.")

(defvar agent-buffers--last-accessed-by-root (make-hash-table :test 'equal)
  "Map working directories to their most recently displayed session buffer.")

(defvar agent-buffers--last-exit-output nil
  "Tail of the terminal output captured when a harness process exited.
Used to explain startup failures, since the session buffer is killed as
part of cleanup and its contents would otherwise be lost.")

;;; Command map

;; The compose commands live in agent-buffers-compose.el; autoload them so the
;; command map can reference them without forcing the load.
(autoload 'agent-buffers-compose-capture "agent-buffers-compose" nil t)
(autoload 'agent-buffers-compose-send-region "agent-buffers-compose" nil t)
(autoload 'agent-buffers-compose-send-defun "agent-buffers-compose" nil t)
(autoload 'agent-buffers-compose-send-buffer "agent-buffers-compose" nil t)
(autoload 'agent-buffers-workspace-create "agent-buffers-jj" nil t)
(autoload 'agent-buffers-sessions-read "agent-buffers-sessions")

(defvar agent-buffers-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "a" (cons "switch to last harness" #'agent-buffers-switch))
    (define-key map "w" (cons "new jj workspace + agent" #'agent-buffers-workspace-create))
    (define-key map "t" (cons "toggle harness window" #'agent-buffers-toggle))
    (define-key map "C" (cons "continue latest session" #'agent-buffers-continue))
    (define-key map "R" (cons "resume: session picker" #'agent-buffers-resume))
    (define-key map "s" (cons "select harness" #'agent-buffers-select))
    (define-key map "S" (cons "switch to session" #'agent-buffers-list-sessions))
    (define-key map "k" (cons "stop harness" #'agent-buffers-stop))
    (define-key map "c" (cons "start compose buffer" #'agent-buffers-compose-capture))
    (define-key map "r" (cons "send region to compose" #'agent-buffers-compose-send-region))
    (define-key map "f" (cons "send function to compose" #'agent-buffers-compose-send-defun))
    (define-key map "b" (cons "send buffer to compose" #'agent-buffers-compose-send-buffer))
    map)
  "Keymap with all agent-buffers commands, to bind under a prefix.
E.g. under the Doom leader and under \\`C-c a' in ghostel buffers.")

;;; Completion (ivy when available)

(defun agent-buffers--completing-read (prompt collection &optional preselect)
  "Pick from COLLECTION with PROMPT, via `ivy-read' when available.
COLLECTION is a list of strings; PRESELECT is the initially selected one."
  (if (fboundp 'ivy-read)
      (ivy-read prompt collection :require-match t :preselect preselect)
    (completing-read prompt collection nil t nil nil preselect)))

;;; Profiles

(defun agent-buffers--profile (harness)
  "Return the profile plist for HARNESS, normalizing a bare string.
An unknown HARNESS signals a plain `error', not a `user-error': it means
a stale `agent-buffers-default-harness' or a renamed profile, and should
fail loudly (and reach `debug-on-error') rather than flash by in the
echo area."
  (let ((p (alist-get harness agent-buffers-harnesses)))
    (cond ((null p)
           (error "Unknown harness `%s' (configured: %s); check `agent-buffers-default-harness' and `agent-buffers-harnesses'"
                  harness
                  (mapconcat #'symbol-name (agent-buffers--harness-names) ", ")))
          ((stringp p) (list :command p))
          (t p))))

(defun agent-buffers--program (harness)
  "Return the program name (argv[0], sans directory) of HARNESS's :command."
  (when-let* ((command (plist-get (agent-buffers--profile harness) :command)))
    (file-name-nondirectory (car (split-string command)))))

(defun agent-buffers--harness-get (harness prop)
  "Look up PROP for HARNESS: its profile first, then its program's traits.
The profile plist (`agent-buffers-harnesses') overrides the program entry
\(`agent-buffers-programs')."
  (or (plist-get (agent-buffers--profile harness) prop)
      (plist-get (cdr (assoc (agent-buffers--program harness)
                             agent-buffers-programs))
                 prop)))

(defun agent-buffers--harness-names ()
  "Return the list of configured harness names."
  (mapcar #'car agent-buffers-harnesses))

(defun agent-buffers--read-harness ()
  "Prompt for a harness name, returning a symbol."
  (intern
   (agent-buffers--completing-read
    "Harness: " (mapcar #'symbol-name (agent-buffers--harness-names))
    (symbol-name agent-buffers-default-harness))))

;;; Workspace detection & naming

(defun agent-buffers--file-string (path)
  "Return the trimmed contents of PATH as a string."
  (string-trim (with-temp-buffer (insert-file-contents path) (buffer-string))))

(defun agent-buffers--strip-dotdir (git-or-jj-dir)
  "Return the repo root for a .jj/.git directory GIT-OR-JJ-DIR.
That is, strip the trailing .jj/.git path component."
  (directory-file-name
   (file-name-directory (directory-file-name git-or-jj-dir))))

(defun agent-buffers--jj-repo-and-workspace (workspace-root)
  "Return (REPO . WORKSPACE) for a jujutsu WORKSPACE-ROOT.
In a secondary workspace, .jj/repo is a file holding a (usually relative)
path to the backing repo's .jj/repo; in the main workspace it is a
directory living under WORKSPACE-ROOT."
  (let* ((workspace (file-name-nondirectory workspace-root))
         (repo-pointer (expand-file-name "repo"
                                         (expand-file-name ".jj" workspace-root)))
         (repo-root
          (if (file-regular-p repo-pointer)
              (let* ((resolved (expand-file-name
                                (agent-buffers--file-string repo-pointer)
                                (file-name-directory repo-pointer))))
                ;; resolved = <repo-root>/.jj/repo -> strip the trailing
                ;; "repo" and ".jj" components to get <repo-root>.
                (agent-buffers--strip-dotdir
                 (directory-file-name (file-name-directory resolved))))
            workspace-root)))
    (cons (file-name-nondirectory repo-root) workspace)))

(defun agent-buffers--git-repo-and-workspace (worktree-root)
  "Return (REPO . WORKTREE) for a git WORKTREE-ROOT.
In a linked worktree, .git is a file \"gitdir: <path>\" pointing at
<common>/.git/worktrees/<name>; in the primary checkout it is a directory."
  (let* ((worktree (file-name-nondirectory worktree-root))
         (git-pointer (expand-file-name ".git" worktree-root))
         (repo-root
          (if (file-directory-p git-pointer)
              worktree-root
            (let* ((gitdir (expand-file-name
                            (replace-regexp-in-string
                             "\\`gitdir: *" ""
                             (agent-buffers--file-string git-pointer))
                            worktree-root))
                   (commondir-file (expand-file-name "commondir" gitdir))
                   (common-git-dir
                    (if (file-exists-p commondir-file)
                        (expand-file-name
                         (agent-buffers--file-string commondir-file) gitdir)
                      ;; Fall back: gitdir = <common>/.git/worktrees/<name>.
                      (directory-file-name
                       (file-name-directory
                        (directory-file-name (file-name-directory gitdir)))))))
              (agent-buffers--strip-dotdir
               (directory-file-name common-git-dir))))))
    (cons (file-name-nondirectory repo-root) worktree)))

(defun agent-buffers-workspace-name (directory)
  "Return a workspace label like \"repo/workspace\" for DIRECTORY.
Detects both jujutsu workspaces and git worktrees; when both are present
\(a colocated repo) jujutsu wins.  WORKSPACE is the working-copy directory
name and REPO is the backing repository.  Falls back to the bare directory
name for plain directories, or when REPO and WORKSPACE coincide (e.g. a
primary checkout / main workspace)."
  (let* ((dir (expand-file-name directory))
         (jj (locate-dominating-file dir ".jj"))
         (git (locate-dominating-file dir ".git"))
         (pair (cond
                (jj (agent-buffers--jj-repo-and-workspace
                     (directory-file-name (expand-file-name jj))))
                (git (agent-buffers--git-repo-and-workspace
                      (directory-file-name (expand-file-name git)))))))
    (cond
     ((null pair) (file-name-nondirectory (directory-file-name dir)))
     ((string= (car pair) (cdr pair)) (cdr pair))
     (t (format "%s/%s" (car pair) (cdr pair))))))

;;; Helpers

(defun agent-buffers--default-buffer-name (directory harness)
  "Default buffer name for HARNESS in DIRECTORY: *HARNESS[repo/workspace]*."
  (format "*%s[%s]*" harness (agent-buffers-workspace-name directory)))

(defun agent-buffers--working-directory ()
  "Return the current project root, or `default-directory'."
  (if-let* ((project (project-current)))
      (expand-file-name (project-root project))
    (expand-file-name default-directory)))

(defun agent-buffers--buffer-name (directory harness)
  "Buffer name for HARNESS in DIRECTORY."
  (funcall agent-buffers-buffer-name-function directory harness))

(defun agent-buffers--key (root harness)
  "Session table key for ROOT and HARNESS."
  (cons root harness))

(defun agent-buffers--context-for (working-dir)
  "Return the context string for WORKING-DIR, or nil."
  (when agent-buffers-context-string
    (let ((dir (file-name-as-directory (expand-file-name working-dir))))
      (when (cl-some
             (lambda (d)
               (string-prefix-p (file-name-as-directory (expand-file-name d)) dir))
             agent-buffers-context-directories)
        agent-buffers-context-string))))

(defun agent-buffers--build-command (harness continue resume working-dir)
  "Build the command line string for HARNESS in WORKING-DIR.
CONTINUE, when non-nil, appends the harness's continue flag.  RESUME
appends the resume flag; when it is a string, it names a session id
that is appended after the flag."
  (let* ((profile (agent-buffers--profile harness))
         (parts (list (or (plist-get profile :command)
                          (error "Harness `%s' has no :command in `agent-buffers-harnesses'"
                                 harness)))))
    (when-let* ((flag (and continue (agent-buffers--harness-get harness :continue-flag))))
      (setq parts (append parts (list flag))))
    (when-let* ((flag (and resume (agent-buffers--harness-get harness :resume-flag))))
      (setq parts (append parts (list flag)))
      (when (stringp resume)
        (setq parts (append parts (list (shell-quote-argument resume))))))
    (when-let* ((ctx (agent-buffers--context-for working-dir))
                (flag (agent-buffers--harness-get harness :system-prompt-flag)))
      (setq parts (append parts (list flag (shell-quote-argument ctx)))))
    (when-let* ((extra (plist-get profile :extra-flags)))
      (unless (string-empty-p extra)
        (setq parts (append parts (list extra)))))
    (string-join parts " ")))

(defun agent-buffers--buffer-tail (buffer &optional max-chars)
  "Return the last MAX-CHARS characters of BUFFER, trimmed, or nil.
MAX-CHARS defaults to 2000.  Returns nil when BUFFER is not live."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (string-trim
       (buffer-substring-no-properties
        (max (point-min) (- (point-max) (or max-chars 2000)))
        (point-max))))))

(defun agent-buffers--cleanup-dead ()
  "Drop dead processes from the session table."
  (maphash (lambda (key process)
             (unless (process-live-p process)
               (remhash key agent-buffers--processes)))
           agent-buffers--processes))

(defun agent-buffers-session-buffer-p (buffer)
  "Return non-nil if BUFFER belongs to a live agent-buffers session."
  (and (bufferp buffer)
       (buffer-live-p buffer)
       (catch 'found
         (maphash (lambda (_key process)
                    (when (eq (process-buffer process) buffer)
                      (throw 'found t)))
                  agent-buffers--processes)
         nil)))

(defun agent-buffers-live-sessions (&optional root)
  "Return an alist of (HARNESS . BUFFER) for live sessions.
When ROOT is non-nil, restrict to sessions rooted there."
  (agent-buffers--cleanup-dead)
  (let (sessions)
    (maphash (lambda (key process)
               (when (or (null root) (equal (car key) root))
                 (push (cons (cdr key) (process-buffer process)) sessions)))
             agent-buffers--processes)
    sessions))

(defun agent-buffers--session-key-for-buffer (buffer)
  "Return the (ROOT . HARNESS) key for BUFFER, or nil."
  (catch 'found
    (maphash (lambda (key process)
               (when (eq (process-buffer process) buffer)
                 (throw 'found key)))
             agent-buffers--processes)
    nil))

(defun agent-buffers--mark-accessed (buffer)
  "Record BUFFER as the most recently accessed session."
  (setq agent-buffers--last-accessed-buffer buffer)
  (when-let* ((key (agent-buffers--session-key-for-buffer buffer)))
    (puthash (car key) buffer agent-buffers--last-accessed-by-root)))

(defun agent-buffers--last-session-buffer (root)
  "Return the most recently accessed live session buffer for ROOT, or nil."
  (let ((buffer (gethash root agent-buffers--last-accessed-by-root)))
    (when (and (buffer-live-p buffer)
               (equal (car-safe (agent-buffers--session-key-for-buffer buffer)) root))
      buffer)))

(defun agent-buffers--fallback-session-buffer (root)
  "Return a deterministic live session buffer for ROOT, or nil."
  (when-let* ((sessions (agent-buffers-live-sessions root)))
    (cdr (car (sort sessions
                    (lambda (a b)
                      (string< (symbol-name (car a))
                               (symbol-name (car b)))))))))

(defun agent-buffers--current-session-buffer ()
  "Return the session buffer a command in this context should target.
The current buffer when it is itself a session; otherwise this project's
live session.  With several sessions, pick one (via ivy), preselecting
the last visited."
  (if (agent-buffers-session-buffer-p (current-buffer))
      (current-buffer)
    (let ((sessions (agent-buffers-live-sessions (agent-buffers--working-directory))))
      (pcase (length sessions)
        (0 (user-error "No harness session for this project"))
        (1 (cdar sessions))
        (_ (get-buffer
            (agent-buffers--completing-read
             "Session: "
             (mapcar (lambda (s) (buffer-name (cdr s))) sessions)
             (and (buffer-live-p agent-buffers--last-accessed-buffer)
                  (buffer-name agent-buffers--last-accessed-buffer)))))))))

;;; Terminal backend abstraction

(defun agent-buffers--ensure-backend ()
  "Ensure the selected terminal backend is loaded."
  (let ((backend agent-buffers-terminal-backend))
    (unless (featurep backend)
      (require backend nil t))
    (unless (featurep backend)
      (user-error "Terminal backend `%s' is not installed" backend))))

(defun agent-buffers--send-string (string)
  "Send STRING to the terminal in the current buffer."
  (pcase agent-buffers-terminal-backend
    ('vterm (vterm-send-string string))
    ('eat (when eat-terminal (eat-term-send-string eat-terminal string)))
    ('ghostel (if (fboundp 'ghostel-send-string)
                  (ghostel-send-string string)
                (when-let* ((p (get-buffer-process (current-buffer))))
                  (process-send-string p string))))
    (_ (error "Unknown terminal backend: %s" agent-buffers-terminal-backend))))

(defun agent-buffers--send-return ()
  "Send a return key to the terminal in the current buffer."
  (pcase agent-buffers-terminal-backend
    ('vterm (vterm-send-return))
    (_ (agent-buffers--send-string "\r"))))

(defun agent-buffers--send-escape-raw ()
  "Send an escape key to the terminal in the current buffer."
  (pcase agent-buffers-terminal-backend
    ('vterm (vterm-send-escape))
    (_ (agent-buffers--send-string "\e"))))

(defun agent-buffers--parse-command (command-string)
  "Split COMMAND-STRING into (PROGRAM . ARGS)."
  (let ((parts (split-string-shell-command command-string)))
    (cons (car parts) (cdr parts))))

(defun agent-buffers--disable-ghostel-title-tracking ()
  "Disable Ghostel OSC title tracking in the current buffer."
  (cond
   ((boundp 'ghostel-set-title-function) (setq-local ghostel-set-title-function nil))
   ((boundp 'ghostel-enable-title-tracking) (setq-local ghostel-enable-title-tracking nil))))

(defun agent-buffers--setup-keybindings ()
  "Set up terminal keybindings in the current buffer."
  (local-set-key (kbd "S-<return>") #'agent-buffers-insert-newline)
  (local-set-key (kbd "C-<escape>") #'agent-buffers-send-escape))

(defun agent-buffers--create-terminal (buffer-name working-dir command)
  "Create a terminal BUFFER-NAME in WORKING-DIR running COMMAND.
Return a cons (BUFFER . PROCESS)."
  (agent-buffers--ensure-backend)
  (let ((default-directory working-dir)
        (env-vars (list "TERM_PROGRAM=emacs")))
    (pcase agent-buffers-terminal-backend
      ('vterm
       (let* ((vterm-buffer-name buffer-name)
              (vterm-shell command)
              (vterm-environment (append env-vars vterm-environment))
              (buffer (save-window-excursion (vterm buffer-name))))
         (unless buffer (error "Failed to create vterm buffer"))
         (let ((process (get-buffer-process buffer)))
           (unless process (error "Failed to get vterm process"))
           (cons buffer process))))
      ('eat
       (let* ((buffer (get-buffer-create buffer-name))
              (eat-term-name "xterm-256color")
              (cmd (agent-buffers--parse-command command)))
         (with-current-buffer buffer
           (unless (eq major-mode 'eat-mode) (eat-mode))
           (setq-local process-environment (append env-vars process-environment))
           (eat-exec buffer buffer-name (car cmd) nil (cdr cmd))
           (let ((process (get-buffer-process buffer)))
             (unless process (error "Failed to create eat process"))
             (setq-local eat-kill-buffer-on-exit t)
             (cons buffer process)))))
      ('ghostel
       (let* ((cmd (agent-buffers--parse-command command)))
         (when-let* ((stale (get-buffer buffer-name))) (kill-buffer stale))
         (let ((buffer (get-buffer-create buffer-name)))
           (with-current-buffer buffer
             (setq default-directory working-dir)
             (agent-buffers--disable-ghostel-title-tracking)
             (setq-local ghostel-kill-buffer-on-exit nil)
             (let* ((process-environment (append env-vars process-environment))
                    (process (ghostel-exec buffer (car cmd) (cdr cmd))))
               (agent-buffers--disable-ghostel-title-tracking)
               (setq-local ghostel-kill-buffer-on-exit nil)
               (unless process (error "Failed to create ghostel process"))
               (process-put process 'agent-buffers--ghostel-sentinel
                            (process-sentinel process))
               (cons buffer process))))))
      (_ (error "Unknown terminal backend: %s" agent-buffers-terminal-backend)))))

;;; Window display

(defun agent-buffers--display-in-side-window (buffer)
  "Display BUFFER in a side window (or a normal one) and update bookkeeping.
With `agent-buffers-use-side-window' nil, BUFFER goes to a regular window
on `agent-buffers-window-side' that can be split like any other.  Windows
already showing BUFFER elsewhere are closed first, so the buffer is
preferentially displayed in its canonical spot."
  (dolist (w (get-buffer-window-list buffer nil))
    (ignore-errors (delete-window w)))
  (let* ((side agent-buffers-window-side)
         (size (if (memq side '(left right))
                   `(window-width . ,agent-buffers-window-width)
                 `(window-height . ,agent-buffers-window-height)))
         (window
          (if agent-buffers-use-side-window
              (let ((display-buffer-alist
                     `((,(regexp-quote (buffer-name buffer))
                        (display-buffer-in-side-window)
                        (side . ,side)
                        (slot . 0)
                        ,size
                        (window-parameters . ((no-delete-other-windows . t)))))))
                (display-buffer buffer))
            ;; leftmost/rightmost place the window at the frame edge (like
            ;; the side window) rather than next to the selected window.
            (display-buffer buffer
                            `(display-buffer-in-direction
                              (direction . ,(pcase side
                                              ('left 'leftmost)
                                              ('right 'rightmost)
                                              (_ side)))
                              ,size)))))
    (agent-buffers--mark-accessed buffer)
    (when (and window agent-buffers-focus-on-open)
      (select-window window))
    (when window
      (agent-buffers--sync-dimensions buffer window))
    window))

(defun agent-buffers--sync-dimensions (buffer window)
  "Sync the terminal in BUFFER to the size of WINDOW."
  (when (and (buffer-live-p buffer) (window-live-p window))
    (when-let* ((proc (get-buffer-process buffer)))
      (set-process-window-size proc (window-body-height window)
                               (window-body-width window)))))

(defun agent-buffers--toggle-window (buffer)
  "Toggle visibility of BUFFER's window."
  (if-let* ((window (get-buffer-window buffer)))
      (progn (agent-buffers--mark-accessed buffer)
             (delete-window window))
    (agent-buffers--display-in-side-window buffer)))

;;; Session lifecycle

(defun agent-buffers--cleanup (key buffer-name)
  "Remove KEY from the table and kill BUFFER-NAME."
  (remhash key agent-buffers--processes)
  (when-let* ((buffer (get-buffer buffer-name)))
    (when (buffer-live-p buffer)
      (let ((kill-buffer-hook nil)
            (kill-buffer-query-functions nil))
        (kill-buffer buffer)))))

(defun agent-buffers--start (harness &optional continue resume working-dir)
  "Start (or toggle) a HARNESS session for the current project.
CONTINUE and RESUME select the harness's respective flags; RESUME may
be a session id string to resume that specific session.  WORKING-DIR
overrides the project root as the session's directory."
  (agent-buffers--cleanup-dead)
  (let* ((working-dir (or working-dir (agent-buffers--working-directory)))
         (buffer-name (agent-buffers--buffer-name working-dir harness))
         (key (agent-buffers--key working-dir harness))
         (existing-buffer (get-buffer buffer-name))
         (existing-process (gethash key agent-buffers--processes)))
    (if (and existing-buffer (buffer-live-p existing-buffer) existing-process)
        (agent-buffers--toggle-window existing-buffer)
      (let* ((command (agent-buffers--build-command harness continue resume working-dir))
             (bp (agent-buffers--create-terminal buffer-name working-dir command))
             (buffer (car bp))
             (process (cdr bp)))
        (puthash key process agent-buffers--processes)
        (let ((prev (process-get process 'agent-buffers--ghostel-sentinel)))
          (set-process-sentinel
           process
           (lambda (proc event)
             (when prev (ignore-errors (funcall prev proc event)))
             (when (string-match-p "\\(finished\\|exited\\|killed\\|terminated\\)" event)
               (setq agent-buffers--last-exit-output
                     (agent-buffers--buffer-tail (process-buffer proc)))
               (agent-buffers--cleanup key buffer-name)))))
        (with-current-buffer buffer
          (add-hook 'kill-buffer-hook
                    (lambda () (agent-buffers--cleanup key buffer-name)) nil t)
          (agent-buffers--setup-keybindings)
          (when (eq agent-buffers-terminal-backend 'vterm)
            (add-hook 'vterm-exit-functions
                      (lambda (&rest _)
                        (when (buffer-live-p buffer) (kill-buffer buffer)))
                      nil t)))
        (when (> agent-buffers-terminal-initialization-delay 0)
          (sleep-for agent-buffers-terminal-initialization-delay))
        ;; If the process died during the settle delay, the exit sentinel has
        ;; already killed the buffer; displaying it would signal a cryptic
        ;; "No such live buffer" error.  Explain what happened instead.
        (unless (buffer-live-p buffer)
          (user-error "%s exited right after startup (command: %s)%s"
                      harness command
                      (if (and agent-buffers--last-exit-output
                               (not (string-empty-p agent-buffers--last-exit-output)))
                          (format "; last output:\n%s" agent-buffers--last-exit-output)
                        "")))
        (agent-buffers--display-in-side-window buffer)
        (message "Started %s in %s" harness
                 (file-name-nondirectory (directory-file-name working-dir)))))))

(defun agent-buffers--switch-to-harness (harness &optional working-dir)
  "Switch to HARNESS in WORKING-DIR, creating it when needed."
  (agent-buffers--cleanup-dead)
  (let* ((working-dir (or working-dir (agent-buffers--working-directory)))
         (buffer-name (agent-buffers--buffer-name working-dir harness))
         (key (agent-buffers--key working-dir harness))
         (buffer (get-buffer buffer-name))
         (process (gethash key agent-buffers--processes)))
    (if (and buffer (buffer-live-p buffer) process)
        (agent-buffers--display-in-side-window buffer)
      (agent-buffers--start harness nil nil working-dir))))

;;; Commands

;;;###autoload
(defun agent-buffers (&optional arg)
  "Open or toggle the default harness for the current project.
With a prefix ARG, prompt for which harness to use."
  (interactive "P")
  (agent-buffers--start (if arg (agent-buffers--read-harness)
                        agent-buffers-default-harness)))

;;;###autoload
(defun agent-buffers-select ()
  "Pick a harness (via ivy when available) and switch to it.
The default harness is preselected, so \\`RET' opens it directly."
  (interactive)
  (agent-buffers--switch-to-harness (agent-buffers--read-harness)))

;;;###autoload
(defun agent-buffers-switch ()
  "Switch to the last visited harness session for this project.
If this project has no live harness sessions yet, prompt for a harness and
create it."
  (interactive)
  (agent-buffers--cleanup-dead)
  (let* ((root (agent-buffers--working-directory))
         (sessions (agent-buffers-live-sessions root)))
    (if (null sessions)
        (agent-buffers-select)
      (agent-buffers--display-in-side-window
       (or (agent-buffers--last-session-buffer root)
           (agent-buffers--fallback-session-buffer root))))))

;;;###autoload
(defun agent-buffers-continue (&optional arg)
  "Open the default harness, continuing the latest session here.
Uses the program's :continue-flag (claude: --continue, codex: resume
--last), which reopens the most recent session for this directory without
prompting.  With a prefix ARG, prompt for which harness to use."
  (interactive "P")
  (agent-buffers--start (if arg (agent-buffers--read-harness)
                        agent-buffers-default-harness)
                      t))

;;;###autoload
(defun agent-buffers-resume (&optional arg)
  "Resume a past session of the default harness in this project.
When the harness's session store can be parsed (the program has a
:sessions-function in `agent-buffers-programs'), pick the session with
`completing-read' -- title and time since last use -- and resume it by
id.  Otherwise fall back to the CLI's own interactive picker via the
program's :resume-flag.  With a prefix ARG, prompt for which harness
to use."
  (interactive "P")
  (let ((harness (if arg (agent-buffers--read-harness)
                   agent-buffers-default-harness)))
    (agent-buffers--start harness nil
                        (or (agent-buffers-sessions-read
                             harness (agent-buffers--working-directory))
                            t))))

;;;###autoload
(defun agent-buffers-toggle (&optional arg)
  "Toggle the default harness window for the current project.
With a prefix ARG, prompt for which harness to toggle."
  (interactive "P")
  (let* ((harness (if arg (agent-buffers--read-harness) agent-buffers-default-harness))
         (buffer-name (agent-buffers--buffer-name (agent-buffers--working-directory) harness))
         (buffer (get-buffer buffer-name)))
    (if buffer
        (agent-buffers--toggle-window buffer)
      (user-error "No %s session for this project" harness))))

;;;###autoload
(defun agent-buffers-stop (&optional arg)
  "Stop the default harness session for the current project.
With a prefix ARG, prompt for which harness to stop."
  (interactive "P")
  (let* ((harness (if arg (agent-buffers--read-harness) agent-buffers-default-harness))
         (buffer-name (agent-buffers--buffer-name (agent-buffers--working-directory) harness)))
    (if-let* ((buffer (get-buffer buffer-name)))
        (progn (kill-buffer buffer)
               (message "Stopped %s" harness))
      (message "No %s session running here" harness))))

;;;###autoload
(defun agent-buffers-list-sessions ()
  "List active harness sessions and switch to the chosen one."
  (interactive)
  (agent-buffers--cleanup-dead)
  (let (sessions)
    (maphash (lambda (key _)
               (push (cons (format "%s  [%s]" (abbreviate-file-name (car key)) (cdr key))
                           key)
                     sessions))
             agent-buffers--processes)
    (if (null sessions)
        (message "No active harness sessions")
      (let* ((choice (agent-buffers--completing-read
                      "Switch to session: " (mapcar #'car sessions)))
             (key (alist-get choice sessions nil nil #'string=))
             (buffer-name (agent-buffers--buffer-name (car key) (cdr key))))
        (if-let* ((buffer (get-buffer buffer-name)))
            (agent-buffers--display-in-side-window buffer)
          (user-error "Buffer for %s no longer exists" choice))))))

;;;###autoload
(defun agent-buffers-send-escape ()
  "Send escape to this buffer's session, or this project's session."
  (interactive)
  (with-current-buffer (agent-buffers--current-session-buffer)
    (agent-buffers--send-escape-raw)))

;;;###autoload
(defun agent-buffers-insert-newline ()
  "Insert a newline (backslash + return) in the harness terminal.
Targets this buffer's session, or this project's session."
  (interactive)
  (with-current-buffer (agent-buffers--current-session-buffer)
    (agent-buffers--send-string "\\")
    (sit-for 0.1)
    (agent-buffers--send-return)))

(provide 'agent-buffers)

;;; agent-buffers.el ends here
