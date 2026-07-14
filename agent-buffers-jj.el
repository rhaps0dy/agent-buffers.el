;;; agent-buffers-jj.el --- jj workspace integration for agent-buffers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Adrià Garriga-Alonso

;; Author: Adrià Garriga-Alonso <adria@theorem.dev>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of agent-buffers; see agent-buffers.el for the
;; full package headers and license.

;;; Commentary:
;;
;; Jujutsu workspace integration: `agent-buffers-workspace-create' makes a new
;; jj workspace under `agent-buffers-workspaces-base'/REPO/NAME and starts a
;; harness in it, so spinning up an agent on a side task is one command.
;;
;; The new workspace's working copy starts on top of:
;;   - the changeset at point, when called from a majutsu buffer;
;;   - the current workspace's @, otherwise.
;;
;; Planned here eventually (see TODO.md): changeset<->session association and
;; a majutsu "pick this changeset up in a workspace + resumed session" action.

;;; Code:

(require 'agent-buffers)

(declare-function majutsu-revision-at-point "majutsu-base")

(defcustom agent-buffers-workspaces-base "~/Programacio/worktrees"
  "Directory under which `agent-buffers-workspace-create' puts workspaces.
Layout is BASE/REPO/NAME, so buffer names come out as *harness[repo/name]*."
  :type 'directory
  :group 'agent-buffers)

(defun agent-buffers-jj--workspace-root (dir)
  "Return the jj workspace root containing DIR, or nil."
  (when-let* ((root (locate-dominating-file (expand-file-name dir) ".jj")))
    (directory-file-name (expand-file-name root))))

(defun agent-buffers-jj--base-revision ()
  "Revision the new workspace's working copy should sit on top of.
The changeset at point in majutsu(-ish) buffers, else \"@\"."
  (or (and (fboundp 'majutsu-revision-at-point)
           (ignore-errors (majutsu-revision-at-point)))
      "@"))

(defun agent-buffers-jj--workspace-add (root name rev dest)
  "Run \"jj workspace add\" in ROOT: workspace NAME at DEST on top of REV.
Signal an error including jj's output when it fails."
  (with-temp-buffer
    (let* ((default-directory root)
           (status (call-process "jj" nil t nil
                                 "workspace" "add" "--name" name
                                 "-r" rev (expand-file-name dest))))
      (unless (eql status 0)
        (error "Command `jj workspace add' failed (%s): %s"
               status (string-trim (buffer-string)))))))

;;;###autoload
(defun agent-buffers-workspace-create (name)
  "Create jj workspace NAME for this repo and start a harness in it.
The workspace goes to `agent-buffers-workspaces-base'/REPO/NAME.  Its
working copy starts on top of the changeset at point when called from a
majutsu buffer, and on top of the current workspace's @ otherwise.
Prompts for which harness to start."
  (interactive (list (read-string "New workspace name: ")))
  (when (string-empty-p (string-trim name))
    (user-error "Workspace name must not be empty"))
  (let* ((root (or (agent-buffers-jj--workspace-root
                    (agent-buffers--working-directory))
                   (user-error "Not inside a jj repo")))
         (rev (agent-buffers-jj--base-revision))
         (repo (car (agent-buffers--jj-repo-and-workspace root)))
         (dest (expand-file-name
                (concat repo "/" name)
                agent-buffers-workspaces-base))
         (harness (agent-buffers--read-harness)))
    (when (file-exists-p dest)
      (user-error "Workspace directory already exists: %s" dest))
    (make-directory (file-name-directory (directory-file-name dest)) t)
    (agent-buffers-jj--workspace-add root name rev dest)
    (message "Created jj workspace %s at %s (on top of %s)" name dest rev)
    (agent-buffers--start harness nil nil (file-name-as-directory dest))))

(provide 'agent-buffers-jj)

;;; agent-buffers-jj.el ends here
