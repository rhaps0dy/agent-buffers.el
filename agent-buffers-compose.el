;;; agent-buffers-compose.el --- Compose buffer for agent-buffers sessions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Adrià Garriga-Alonso

;; Author: Adrià Garriga-Alonso <adria@theorem.dev>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of agent-buffers; see agent-buffers.el for the
;; full package headers and license.

;;; Commentary:
;;
;; A normal Emacs buffer for composing messages to a project's harness
;; session (see agent-buffers.el), instead of typing into the fiddly
;; terminal TUI.
;;
;; Highlights:
;;   - Each project gets a compose buffer, opened in a window split below
;;     so the harness and the compose buffer are both visible.  When a
;;     project has several live sessions, you pick the target (via ivy).
;;   - `agent-buffers-compose-send-region' / `-defun' / `-buffer' work in ANY
;;     buffer; they drop a "path (lines A-B)" reference plus the copied code
;;     into the compose buffer (patterned after `python-shell-send-*').
;;   - In the compose buffer, `C-c C-f' inserts "@<file>" picking among the
;;     project's files (via ivy when available).
;;   - `C-c C-c' (send) and `C-c C-k' (abort) both archive the message to a
;;     per-project history dir, then clear and delete the buffer.
;;   - `C-c C-y' inserts a past message back from that history.

;;; Code:

(require 'agent-buffers)
(require 'markdown-mode nil t)

(define-derived-mode agent-buffers-compose-mode markdown-mode "CLI-Compose"
  "Major mode for composing a message to send to a harness session.")

;; Start composing in insert state so you can type right away.
(when (fboundp 'evil-set-initial-state)
  (evil-set-initial-state 'agent-buffers-compose-mode 'insert))

;;; ----------------------------------------------------------------------
;;; Options & buffer-local state
;;; ----------------------------------------------------------------------

(defgroup agent-buffers-compose nil
  "Compose buffer for agent-buffers harness sessions."
  :group 'agent-buffers)

(defcustom agent-buffers-compose-paste t
  "When non-nil, send composed text to the harness as one bracketed paste.
Bracketed paste lets the harness treat embedded newlines as literal
newlines instead of submitting early.  If your harness mishandles it,
set this to nil to fall back to sending each line followed by the
backslash+RET newline that `agent-buffers-insert-newline' uses."
  :type 'boolean
  :group 'agent-buffers-compose)

(defcustom agent-buffers-compose-history-dir
  (expand-file-name "agent-buffers-history"
                    (or (bound-and-true-p doom-state-dir) user-emacs-directory))
  "Directory under which composed messages are archived per project."
  :type 'directory
  :group 'agent-buffers-compose)

(defvar-local agent-buffers-compose-target nil
  "Buffer name of the harness session this compose buffer feeds.")

;;; ----------------------------------------------------------------------
;;; Project / path helpers
;;; ----------------------------------------------------------------------

(defun agent-buffers-compose--project-root ()
  "Best-effort project root of the current buffer."
  (agent-buffers--working-directory))

(defun agent-buffers-compose--project-name ()
  "Short name for the current project, used for history sub-directories."
  (file-name-nondirectory
   (directory-file-name (agent-buffers-compose--project-root))))

(defun agent-buffers-compose--relative-path (path)
  "Return PATH relative to the project root when it lives inside it."
  (let ((root (agent-buffers-compose--project-root)))
    (if (and root (string-prefix-p (expand-file-name root)
                                   (expand-file-name path)))
        (file-relative-name path root)
      path)))

(defun agent-buffers-compose--buffer-file-ref ()
  "Return a reference string for the current buffer.
Its project-relative path, or its buffer name when it is not
visiting a file."
  (if buffer-file-name
      (agent-buffers-compose--relative-path buffer-file-name)
    (buffer-name)))

;;; ----------------------------------------------------------------------
;;; The compose buffer
;;; ----------------------------------------------------------------------

(defun agent-buffers-compose--get-compose-buffer (target root)
  "Get or create the compose buffer for session TARGET rooted at ROOT."
  (let ((buf (get-buffer-create
              (format "*compose[%s]*" (agent-buffers-workspace-name root)))))
    (with-current-buffer buf
      (unless (derived-mode-p 'agent-buffers-compose-mode)
        (agent-buffers-compose-mode))
      (setq default-directory root
            agent-buffers-compose-target target))
    buf))

(defun agent-buffers-compose--prepare-compose ()
  "Return the compose buffer for the current project's harness session.
Signals a `user-error' when there is no live session."
  (let* ((root (agent-buffers-compose--project-root))
         (target (buffer-name (agent-buffers--current-session-buffer))))
    (agent-buffers-compose--get-compose-buffer target root)))

(defun agent-buffers-compose--display-compose (buf)
  "Show BUF in a small window at the bottom, and select it."
  (pop-to-buffer buf
                 '((display-buffer-reuse-window display-buffer-in-direction)
                   (direction . down)
                   (window-height . 20))))

;;; ----------------------------------------------------------------------
;;; Sending text to the live session
;;; ----------------------------------------------------------------------

(defun agent-buffers-compose--send-text (target text)
  "Send TEXT to the harness session buffer named TARGET, then submit."
  (with-current-buffer target
    (if agent-buffers-compose-paste
        (agent-buffers--send-string
         (concat "\e[200~" text "\e[201~"))
      (let ((lines (split-string text "\n")))
        (while lines
          (agent-buffers--send-string (pop lines))
          (when lines                 ; newline between lines, not after the last
            (agent-buffers--send-string "\\")
            (sit-for 0.05)
            (agent-buffers--send-return)))))
    (sit-for 0.05)
    (agent-buffers--send-return)))

;;; ----------------------------------------------------------------------
;;; Sending code snippets from any buffer
;;; ----------------------------------------------------------------------

(defun agent-buffers-compose--send-snippet (file start-line end-line text)
  "Append a snippet to the project's compose buffer, then show it.
The snippet is a FILE reference for lines START-LINE..END-LINE plus
TEXT itself, fenced."
  (let ((buf (agent-buffers-compose--prepare-compose))
        (line-range (when (and start-line end-line)
                      (format "%d-%d" start-line end-line))))
    (with-current-buffer buf
      ;; Ensure the two previous characters are newlines, unless at the beginning of buffer
      (when (> (point) (point-min))
        (if (eq (char-before (point)) ?\n)
            (if (eq (char-before (1- (point))) ?\n)
                nil ; pass
              (insert "\n"))
          (insert "\n\n")))
      ;; don't insert @ before the filename, because if we do so, Claude Code
      ;; sends the thing inside to Claude twice.
      (insert (format "%s:%s\n\n```\n%s\n```\n"
                      file line-range
                      (string-trim-right text)))
      (goto-char (point-max)))
    (agent-buffers-compose--display-compose buf)))

(defun agent-buffers-compose--send-thing (beg end)
  "Send the region BEG..END of the current buffer as a referenced snippet."
  (let* ((end (if (and (> end beg) (eq (char-before end) ?\n)) (1- end) end))
         (start-line (line-number-at-pos beg))
         (end-line (line-number-at-pos end)))
    (agent-buffers-compose--send-snippet (agent-buffers-compose--buffer-file-ref)
                                       start-line end-line
                                       (buffer-substring-no-properties beg end))))

;;;###autoload
(defun agent-buffers-compose-send-region (beg end)
  "Send the region BEG..END to this project's compose buffer."
  (interactive "r")
  (agent-buffers-compose--send-thing beg end))

;;;###autoload
(defun agent-buffers-compose-send-defun ()
  "Send the function at point to this project's compose buffer."
  (interactive)
  (let ((bounds (bounds-of-thing-at-point 'defun)))
    (unless bounds (user-error "No function at point"))
    (agent-buffers-compose--send-thing (car bounds) (cdr bounds))))

;;;###autoload
(defun agent-buffers-compose-send-buffer ()
  "Send the whole current buffer to this project's compose buffer."
  (interactive)
  (agent-buffers-compose--send-thing (point-min) (point-max)))

;;; ----------------------------------------------------------------------
;;; @file references inside the compose buffer
;;; ----------------------------------------------------------------------

(defun agent-buffers-compose--project-files (root)
  "Return ROOT's project files as paths relative to ROOT, or nil."
  (when-let* ((project (project-current nil root)))
    (mapcar (lambda (f) (file-relative-name f root))
            (project-files project))))

(defun agent-buffers-compose-insert-file-reference ()
  "Insert \"@<file>\" at point, picking among the project's files.
Uses ivy when available; falls back to `read-file-name' outside a
project."
  (interactive)
  (let* ((root (agent-buffers-compose--project-root))
         (files (agent-buffers-compose--project-files root))
         (file (if files
                   (agent-buffers--completing-read "Insert @file: " files)
                 (agent-buffers-compose--relative-path
                  (expand-file-name (read-file-name "Insert @file: "))))))
    (insert "@" file)))

;;; ----------------------------------------------------------------------
;;; History: archive on send/abort, and re-insert later
;;; ----------------------------------------------------------------------

(defun agent-buffers-compose--history-dir ()
  "Per-project history directory, created if necessary."
  (let ((dir (expand-file-name (agent-buffers-compose--project-name)
                               agent-buffers-compose-history-dir)))
    (make-directory dir t)
    dir))

(defun agent-buffers-compose--save-history ()
  "Archive the (non-empty) compose buffer to the project history dir."
  (let ((text (string-trim (buffer-string))))
    (unless (string-empty-p text)
      (let ((file (expand-file-name
                   (format-time-string "%Y-%m-%d_%H-%M-%S.md")
                   (agent-buffers-compose--history-dir))))
        (write-region text nil file nil 'silent)
        file))))

(defun agent-buffers-compose--history-label (file)
  "A one-line label for history FILE: its timestamp plus its first line."
  (let ((first-line (with-temp-buffer
                      (insert-file-contents file nil 0 4000)
                      (goto-char (point-min))
                      (buffer-substring-no-properties
                       (point) (line-end-position)))))
    (format "%s  %s" (file-name-base file) (string-trim first-line))))

(defun agent-buffers-compose-insert-history ()
  "Insert a previously composed message from this project's history.
The candidates are ordered newest-first."
  (interactive)
  (let* ((dir (agent-buffers-compose--history-dir))
         (files (sort (directory-files dir t "\\.md\\'") #'string>)))
    (unless files (user-error "No compose history for this project"))
    (let* ((cands (mapcar (lambda (f)
                            (cons (agent-buffers-compose--history-label f) f))
                          files))
           (choice (agent-buffers--completing-read
                    "Insert from history: " (mapcar #'car cands)))
           (file (cdr (assoc choice cands))))
      (when file (insert-file-contents file)))))

;;; ----------------------------------------------------------------------
;;; Entry point + send / abort
;;; ----------------------------------------------------------------------

;;;###autoload
(defun agent-buffers-compose-capture ()
  "Open a compose buffer for this project's harness session.
With an active region, send it instead of opening an empty buffer."
  (interactive)
  (if (use-region-p)
      (agent-buffers-compose-send-region (region-beginning) (region-end))
    (agent-buffers-compose--display-compose
     (agent-buffers-compose--prepare-compose))))

(defun agent-buffers-compose--kill ()
  "Clear and delete the compose buffer, removing its window if possible."
  (let* ((buf (current-buffer))
         (win (get-buffer-window buf)))
    (if win (quit-restore-window win 'kill)
      (kill-buffer buf))))

(defun agent-buffers-compose-send ()
  "Archive, send the compose buffer to its harness session, then clear it."
  (interactive)
  (let ((target agent-buffers-compose-target)
        (text (string-trim-right (buffer-string))))
    (unless (and target (get-buffer target))
      (user-error "Harness session %s is gone" target))
    (agent-buffers-compose--save-history)
    (unless (string-empty-p text)
      (agent-buffers-compose--send-text target text))
    (agent-buffers-compose--kill)))

(defun agent-buffers-compose-abort ()
  "Archive the compose buffer, then clear and delete it without sending."
  (interactive)
  (agent-buffers-compose--save-history)
  (agent-buffers-compose--kill))

;;; ----------------------------------------------------------------------
;;; Keys
;;; ----------------------------------------------------------------------

(define-key agent-buffers-compose-mode-map (kbd "C-c C-c") #'agent-buffers-compose-send)
(define-key agent-buffers-compose-mode-map (kbd "C-c C-k") #'agent-buffers-compose-abort)
(define-key agent-buffers-compose-mode-map (kbd "C-c C-f") #'agent-buffers-compose-insert-file-reference)
(define-key agent-buffers-compose-mode-map (kbd "C-c C-y") #'agent-buffers-compose-insert-history)

(provide 'agent-buffers-compose)

;;; agent-buffers-compose.el ends here
