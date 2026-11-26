;;; pnotes-ui.el --- Tabulated views for pnotes -*- lexical-binding: t; -*-

;;; Commentary:

;; Provides `pnotes-view-mode', backing both `pnotes-inbox-review' and
;; the `pnotes' welcome page on top of Emacs's `tabulated-list-mode'.

;;; Code:

(require 'pnotes)
(require 'tabulated-list)
(require 'button)

(defvar-local pnotes-ui--action-fn nil
  "Row activation callback `(FUNCALL FN ID)' for this view buffer.")

(defvar-local pnotes-ui--refresh-fn nil
  "Callback registered on `pnotes-navigation-hook' for this view buffer.")

(defun pnotes-ui-act (&optional button)
  "Invoke `pnotes-ui--action-fn' on the current row (or at BUTTON)."
  (interactive)
  (if-let* ((pnotes-ui--action-fn)
            (id (tabulated-list-get-id (and button (button-start button)))))
      (progn
        (when-let* ((button) (win (get-buffer-window (current-buffer))))
          (select-window win))
        (funcall pnotes-ui--action-fn id))
    (user-error "No entry at point")))

(defun pnotes-ui--button (label)
  "Return a `tabulated-list' button descriptor for LABEL."
  (list label 'face 'link 'follow-link t 'action #'pnotes-ui-act))

(defun pnotes-ui--unsubscribe ()
  "Remove this buffer's live refresh callback from `pnotes-navigation-hook'."
  (when pnotes-ui--refresh-fn
    (remove-hook 'pnotes-navigation-hook pnotes-ui--refresh-fn)
    (setq pnotes-ui--refresh-fn nil)))

(defvar-keymap pnotes-view-mode-map
  :doc "Keymap for `pnotes-view-mode'."
  "RET" #'pnotes-ui-act
  "f" #'pnotes-ui-act
  "v" #'pnotes-ui-act)

(define-derived-mode pnotes-view-mode tabulated-list-mode "PNotes-View"
  "Generic tabulated view mode for `pnotes' projections."
  (setq tabulated-list-padding 2)
  (when (pnotes-project-root)
    (pnotes-mode 1))
  (add-hook 'kill-buffer-hook #'pnotes-ui--unsubscribe nil t)
  (add-hook 'change-major-mode-hook #'pnotes-ui--unsubscribe nil t))

(defun pnotes-ui--open (name root format sort-key entries-fn action-fn
                             &optional live-events same-window-p revert-fn)
  "Open or refresh a `pnotes-view-mode' buffer for ROOT."
  (let* ((repo (file-name-nondirectory (directory-file-name root)))
         (buf (get-buffer-create (format "*%s: %s*" name repo))))
    (with-current-buffer buf
      (setq-local default-directory root)
      (pnotes-view-mode)
      (setq-local tabulated-list-format format
                  tabulated-list-sort-key sort-key
                  tabulated-list-entries entries-fn
                  pnotes-ui--action-fn action-fn)
      (add-hook 'tabulated-list-revert-hook
                (lambda ()
                  (pnotes-cache-reconcile)
                  (when revert-fn (funcall revert-fn)))
                nil t)
      (when live-events
        (setq pnotes-ui--refresh-fn
              (lambda (r _file event)
                (when (and (memq event live-events) (buffer-live-p buf))
                  (with-current-buffer buf
                    (when (equal r (pnotes-project-root))
                      (tabulated-list-print t))))))
        (add-hook 'pnotes-navigation-hook pnotes-ui--refresh-fn))
      (when revert-fn (funcall revert-fn))
      (tabulated-list-init-header)
      (tabulated-list-print t)
      (goto-char (point-min)))
    (when same-window-p (pnotes--ensure-main-window))
    (if same-window-p (pop-to-buffer-same-window buf) (pop-to-buffer buf))))

;;; Inbox triage and welcome projections

(defun pnotes--inbox-entries ()
  "Project notes requiring triage (inbox, untagged, or unlinked)."
  (when-let* ((root (pnotes-project-root)))
    (let ((inbox-pfx (file-name-as-directory pnotes-inbox-directory)))
      (pnotes-cache-query
       root
       (lambda (rel meta cache)
         (when-let* ((issues (delq nil
                                   (list (and (string-prefix-p inbox-pfx rel) "inbox")
                                         (and (null (plist-get meta :tags)) "untagged")
                                         (and (null (pnotes--backlink-sources
                                                     cache (plist-get meta :projections) rel))
                                              "unlinked")))))
           (list (expand-file-name rel root)
                 (vector (pnotes-ui--button (plist-get meta :title))
                         (format-time-string "%Y-%m-%d" (plist-get meta :mtime))
                         (string-join issues ", ")))))))))

;;;###autoload
(defun pnotes-inbox-review ()
  "Open the triage table of inbox, untagged, and unlinked project notes."
  (interactive)
  (let ((root (pnotes--require-root)))
    (pnotes-ui--open "pnotes-inbox" root
                     [("Title" 40 t) ("Date" 12 t) ("Issues" 30 t)]
                     '("Date" . t)
                     #'pnotes--inbox-entries
                     (lambda (abs) (pnotes--open-note (pnotes-project-root) abs 'follow))
                     '(save capture))))

(defun pnotes--welcome-entries ()
  "Project `pnotes-command-map' bindings into `tabulated-list-entries'."
  (let (entries)
    (map-keymap
     (lambda (event _def)
       (when-let* ((cmd (lookup-key pnotes-command-map (vector event)))
                   ((symbolp cmd))
                   ((commandp cmd))
                   (key-seq (format "%s %s" pnotes-keymap-prefix
                                    (key-description (vector event))))
                   (doc (car (split-string (or (documentation cmd t) "") "\n"))))
         (push (list cmd
                     (vector (propertize key-seq 'face 'help-key-binding)
                             (pnotes-ui--button (symbol-name cmd))
                             doc))
               entries)))
     pnotes-command-map)
    entries))

;;;###autoload
(defun pnotes ()
  "Open the PNotes welcome page for the active or chosen project."
  (interactive)
  (let ((root (pnotes--require-root
               (pnotes-project-root nil (called-interactively-p 'any)))))
    (pnotes-ui--open
     "pnotes" root
     [("Key" 14 t) ("Command" 28 t) ("Description" 55 nil)]
     '("Key" . nil)
     #'pnotes--welcome-entries
     #'call-interactively
     nil t
     (lambda ()
       (when-let* ((proj-root (pnotes-project-root)))
         (let* ((cache (pnotes--ensure-cache proj-root))
                (repo (file-name-nondirectory (directory-file-name proj-root)))
                (count (hash-table-count (pnotes--cache-files cache))))
           (setq mode-name (format "PNotes[%s: %d %s]"
                                   repo count (if (= count 1) "note" "notes")))))))))

(provide 'pnotes-ui)
;;; pnotes-ui.el ends here
