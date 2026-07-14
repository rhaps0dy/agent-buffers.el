;;; agent-buffers-sessions.el --- Parse harness session stores  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Adrià Garriga-Alonso

;; Author: Adrià Garriga-Alonso <adria@theorem.dev>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of agent-buffers; see agent-buffers.el for the
;; full package headers and license.

;;; Commentary:
;;
;; Parse the on-disk session stores of the harness CLIs so that
;; `agent-buffers-resume' can offer the sessions of the current
;; project/workspace in a `completing-read' picker (ivy when available)
;; instead of dropping into each CLI's own TUI picker.  One parser per
;; CLI, wired up via the :sessions-function key of `agent-buffers-programs':
;;
;;   claude    ~/.claude/projects/<munged-cwd>/<session-id>.jsonl
;;             One JSONL transcript per session; the directory name is
;;             the working directory with every non-alphanumeric
;;             character replaced by "-".  Title: the session's summary
;;             record when present, else the first real user prompt.
;;
;;   codex     ~/.codex/sessions/YYYY/MM/DD/rollout-<stamp>-<id>.jsonl
;;             Sharded by date, not by directory: the first line is a
;;             session_meta record carrying cwd and id, so we read the
;;             head of every rollout file and filter by cwd.  Title:
;;             the first user_message event.
;;
;;   opencode  $XDG_DATA_HOME/opencode/opencode.db
;;             SQLite; the session table has directory, title and
;;             time_updated columns, so this one is a plain query
;;             (via the built-in sqlite support, falling back to the
;;             sqlite3 binary).
;;
;; Each parser takes a directory and returns a list of
;; (:id ID :title TITLE :time TIME) plists; TIME is anything
;; `time-less-p' accepts (Lisp timestamp or epoch seconds).

;;; Code:

(require 'cl-lib)
(require 'agent-buffers)

;;; Generic layer

;;;###autoload
(defun agent-buffers-sessions-read (harness directory)
  "Pick a past HARNESS session in DIRECTORY and return its id.
The sessions come from the harness program's :sessions-function (see
`agent-buffers-programs').  Return nil when the harness has no session
parser or no past sessions here -- callers then fall back to the CLI's
own interactive picker."
  (when-let* ((fn (agent-buffers--harness-get harness :sessions-function))
              ((fboundp fn))
              (sessions (funcall fn directory)))
    (let* ((sessions (sort sessions
                           (lambda (a b)
                             (time-less-p (plist-get b :time)
                                          (plist-get a :time)))))
           (candidates
            (mapcar (lambda (session)
                      (cons (format "%-4s %s"
                                    (agent-buffers-sessions--age
                                     (plist-get session :time))
                                    (agent-buffers-sessions--clean-title
                                     (plist-get session :title)))
                            (plist-get session :id)))
                    sessions))
           (choice (agent-buffers--completing-read
                    (format "Resume %s session: " harness)
                    (mapcar #'car candidates))))
      (cdr (assoc choice candidates)))))

(defun agent-buffers-sessions--age (time)
  "Compact age of TIME: \"5m\", \"3h\", \"12d\", else an ISO date."
  (let ((secs (max 0 (float-time (time-since time)))))
    (cond ((< secs 3600) (format "%dm" (max 1 (floor secs 60))))
          ((< secs 86400) (format "%dh" (floor secs 3600)))
          ((< secs (* 90 86400)) (format "%dd" (floor secs 86400)))
          (t (format-time-string "%Y-%m-%d" time)))))

(defun agent-buffers-sessions--clean-title (title)
  "Collapse TITLE to one truncated line."
  (let ((one-line (string-join (split-string (or title "") "[ \t\n]+" t) " ")))
    (if (string-empty-p one-line)
        "(no title)"
      (truncate-string-to-width one-line 78 nil nil t))))

(defun agent-buffers-sessions--file-head (file bytes)
  "Return the first BYTES of FILE as a decoded string."
  (with-temp-buffer
    (insert-file-contents file nil 0 bytes)
    (buffer-string)))

(defun agent-buffers-sessions--json-line (line)
  "Parse the JSONL LINE into an alist, or nil if it is malformed.
Malformed lines are expected: reading a bounded head of a file usually
truncates the last line."
  (ignore-errors
    (json-parse-string line :object-type 'alist :array-type 'array)))

;;; Claude Code

(defvar agent-buffers-sessions-claude-directory "~/.claude/projects/"
  "Where Claude Code keeps its per-project session transcripts.")

(defun agent-buffers-sessions-claude (directory)
  "Return past Claude Code sessions for DIRECTORY."
  (let ((project-dir
         ;; claude munges the cwd into a directory name by replacing
         ;; every non-alphanumeric character with "-".
         (expand-file-name
          (replace-regexp-in-string
           "[^A-Za-z0-9]" "-"
           (directory-file-name (expand-file-name directory)))
          agent-buffers-sessions-claude-directory)))
    (when (file-directory-p project-dir)
      (cl-loop for file in (directory-files project-dir t "\\.jsonl\\'")
               when (file-regular-p file)
               collect (list :id (file-name-base file)
                             :title (agent-buffers-sessions--claude-title file)
                             :time (file-attribute-modification-time
                                    (file-attributes file)))))))

(defun agent-buffers-sessions--claude-title (file)
  "Title for the Claude Code session transcript FILE.
Prefer a summary record (present in continued/compacted sessions),
else the first real user prompt."
  (catch 'title
    (dolist (line (split-string
                   (agent-buffers-sessions--file-head file 65536) "\n" t))
      (when-let* ((record (agent-buffers-sessions--json-line line)))
        (pcase (alist-get 'type record)
          ("summary"
           (when-let* ((summary (alist-get 'summary record)))
             (throw 'title summary)))
          ("user"
           (unless (eq (alist-get 'isMeta record) t)
             (when-let* ((text (agent-buffers-sessions--claude-user-text
                                (alist-get 'content
                                           (alist-get 'message record)))))
               (throw 'title text)))))))
    nil))

(defun agent-buffers-sessions--claude-user-text (content)
  "First piece of human text in a Claude user-message CONTENT, or nil.
CONTENT is either a plain string or a vector of content blocks.
Machine-generated turns (slash-command wrappers, system reminders,
caveats) are skipped."
  (let ((text (cond ((stringp content) content)
                    ((vectorp content)
                     (cl-loop for block across content
                              when (equal (alist-get 'type block) "text")
                              return (alist-get 'text block))))))
    (and (stringp text)
         (not (string-prefix-p "<" (string-trim-left text)))
         (not (string-prefix-p "Caveat:" text))
         text)))

;;; Codex

(defvar agent-buffers-sessions-codex-directory "~/.codex/sessions/"
  "Where codex keeps its rollout files, sharded by date.")

(defun agent-buffers-sessions-codex (directory)
  "Return past codex sessions for DIRECTORY.
Rollouts are sharded by date rather than project, so this reads the
head of every rollout file and keeps the ones whose session_meta cwd
matches DIRECTORY."
  (let ((root (expand-file-name agent-buffers-sessions-codex-directory))
        (dir (directory-file-name (expand-file-name directory)))
        sessions)
    (when (file-directory-p root)
      (dolist (file (directory-files-recursively
                     root "\\`rollout-.*\\.jsonl\\'"))
        ;; The first line (session_meta) embeds the full base
        ;; instructions, so it alone can run tens of kilobytes.
        (let* ((head (agent-buffers-sessions--file-head file 131072))
               (meta (agent-buffers-sessions--json-line
                      (substring head 0 (string-search "\n" head))))
               (payload (alist-get 'payload meta)))
          (when (and (equal (alist-get 'type meta) "session_meta")
                     (equal (alist-get 'cwd payload) dir))
            (push (list :id (alist-get 'id payload)
                        :title (agent-buffers-sessions--codex-title head)
                        :time (file-attribute-modification-time
                               (file-attributes file)))
                  sessions)))))
    sessions))

(defun agent-buffers-sessions--codex-title (head)
  "First user message in the codex rollout HEAD, or nil."
  (cl-loop for line in (split-string head "\n" t)
           when (string-search "\"user_message\"" line)
           do (when-let* ((record (agent-buffers-sessions--json-line line))
                          (payload (alist-get 'payload record))
                          ((equal (alist-get 'type payload) "user_message"))
                          (message (alist-get 'message payload))
                          ((not (string-prefix-p "<" (string-trim-left message)))))
                (cl-return message))))

;;; opencode

(defvar agent-buffers-sessions-opencode-database
  (expand-file-name "opencode/opencode.db"
                    (or (getenv "XDG_DATA_HOME") "~/.local/share"))
  "The opencode SQLite database.")

(defconst agent-buffers-sessions--opencode-query
  (concat "SELECT id, title, time_updated FROM session"
          " WHERE directory = ? AND parent_id IS NULL"
          " ORDER BY time_updated DESC")
  "Query for opencode sessions in a directory, newest first.
parent_id IS NULL excludes subagent child sessions.")

(defun agent-buffers-sessions-opencode (directory)
  "Return past opencode sessions for DIRECTORY."
  (let ((db agent-buffers-sessions-opencode-database)
        (dir (directory-file-name (expand-file-name directory))))
    (when (file-readable-p db)
      (mapcar (pcase-lambda (`(,id ,title ,updated))
                (list :id id :title title
                      :time (/ updated 1000.0))) ; ms epoch -> seconds
              (if (and (fboundp 'sqlite-available-p) (fboundp 'sqlite-open)
                       (fboundp 'sqlite-select) (fboundp 'sqlite-close)
                       (sqlite-available-p))
                  (let ((handle (sqlite-open db)))
                    (unwind-protect
                        (sqlite-select handle
                                       agent-buffers-sessions--opencode-query
                                       (list dir))
                      (sqlite-close handle)))
                (agent-buffers-sessions--opencode-cli db dir))))))

(defun agent-buffers-sessions--opencode-cli (db dir)
  "Query DB for opencode sessions in DIR via the sqlite3 binary.
Fallback for Emacsen built without SQLite support."
  (when (executable-find "sqlite3")
    (let ((query (string-replace
                  "?" (format "'%s'" (string-replace "'" "''" dir))
                  agent-buffers-sessions--opencode-query)))
      (mapcar (lambda (line)
                (pcase-let ((`(,id ,title ,updated)
                             (split-string line "\x1f")))
                  (list id title (string-to-number updated))))
              (split-string
               (with-output-to-string
                 (call-process "sqlite3" nil standard-output nil
                               "-readonly" "-separator" "\x1f" db query))
               "\n" t)))))

(provide 'agent-buffers-sessions)

;;; agent-buffers-sessions.el ends here
