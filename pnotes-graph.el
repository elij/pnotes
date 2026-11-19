;;; pnotes-graph.el --- Force-directed graph view for pnotes via graph-fa2 -*- lexical-binding: t; -*-

;;; Commentary:

;; Renders full or N-hop local project note graphs inside a docked side
;; window using optional `graph-fa2', reading edges and backlink counts
;; directly from `pnotes.el''s incremental session cache.

;;; Code:

(require 'pnotes)
(require 'face-remap)
(require 'graph-fa2 nil t)

(declare-function graph-fa2-start "graph-fa2" (buf nodes edges &key cache-dir))
(declare-function graph-fa2-player-stop "graph-fa2" ())
(defvar graph-fa2-playback-buffer)
(defvar graph-fa2-node-clicked-functions)

(defcustom pnotes-graph-bg-color "#282c34"
  "Background hex colour for the `pnotes-graph' buffer."
  :type 'string
  :group 'pnotes)

(defcustom pnotes-graph-node-color "#89b4fa"
  "Default node fill colour for `pnotes-graph'."
  :type 'string
  :group 'pnotes)

(defcustom pnotes-graph-tag-groups nil
  "Alist of (TAG . \"#HEXCODE\") pairs mapping note tags to node colours.
The first matching tag wins."
  :type '(alist :key-type string :value-type string)
  :group 'pnotes)

(defcustom pnotes-graph-max-distance nil
  "Integer hop limit for local graphs, or nil for the full repository graph."
  :type '(choice (const :tag "Full graph" nil) integer)
  :group 'pnotes)

(defcustom pnotes-graph-cache-directory
  (locate-user-emacs-file "pnotes-graph-cache")
  "Base directory for per-project `:cache-dir' storage in `graph-fa2-start'."
  :type 'directory
  :group 'pnotes)

(defvar-local pnotes-graph--center nil
  "Project-relative path of the focal note for local graph filtering, or nil.")

(defvar-local pnotes-graph--max-hops nil
  "Maximum hop count for local graph filtering, or nil for the full graph.")

(defvar-local pnotes-graph--bg-cookie nil
  "Face remapping cookie for `pnotes-graph-bg-color'.")

(defun pnotes-graph--cache-dir (root)
  "Return a per-project cache directory for `graph-fa2-start' under ROOT."
  (let* ((repo (file-name-nondirectory (directory-file-name root)))
         (subdir (format "%s-%s" repo (substring (md5 root) 0 8))))
    (expand-file-name subdir pnotes-graph-cache-directory)))

(defun pnotes-graph--node-colour (tags)
  "Return the hex colour for a note with TAGS."
  (or (cl-some (lambda (pair)
                 (when (cl-member (car pair) tags :test #'string-equal-ignore-case)
                   (cdr pair)))
               pnotes-graph-tag-groups)
      pnotes-graph-node-color))

(defun pnotes-graph--prepare-data (cache &optional center-rel max-hops)
  "Build `graph-fa2-start' payload (:nodes NODES :edges EDGES) from CACHE.
Projects link key groups from cached `:links' tuples in `pnotes--cache-files'
and derives node prominence from incoming graph edges."
  (let* ((files-tbl (pnotes--cache-files cache))
         (edge-set (make-hash-table :test #'equal))
         (adj (make-hash-table :test #'equal))
         (in-deg (make-hash-table :test #'equal))
         visited nodes edges)
    ;; 1. Resolve directed edges directly from cached :links tuples
    (maphash
     (lambda (src-rel meta)
       (dolist (link (plist-get meta :links))
         (dolist (tgt-rel (pnotes-cache-resolve-link-group (cadr link) cache))
           (unless (string= src-rel tgt-rel)
             (let ((pair (cons src-rel tgt-rel)))
               (unless (gethash pair edge-set)
                 (puthash pair t edge-set)
                 (cl-incf (gethash tgt-rel in-deg 0))
                 (puthash src-rel
                          (cl-adjoin tgt-rel (gethash src-rel adj) :test #'string=)
                          adj)
                 (puthash tgt-rel
                          (cl-adjoin src-rel (gethash tgt-rel adj) :test #'string=)
                          adj)))))))
     files-tbl)
    ;; 2. Optional BFS hop filtering around CENTER-REL
    (when (and (integerp max-hops) (> max-hops 0)
               center-rel (gethash center-rel files-tbl))
      (setq visited (make-hash-table :test #'equal))
      (puthash center-rel t visited)
      (let ((frontier (list center-rel))
            (depth 0))
        (while (and frontier (< depth max-hops))
          (let (next)
            (dolist (u frontier)
              (dolist (v (gethash u adj))
                (unless (gethash v visited)
                  (puthash v t visited)
                  (push v next))))
            (setq frontier next
                  depth (1+ depth))))))
    ;; 3. Assemble sorted :nodes (radii from incoming edge count) and :edges
    (dolist (rel (sort (hash-table-keys (or visited files-tbl)) #'string<))
      (let* ((meta (gethash rel files-tbl))
             (title (plist-get meta :title))
             (colour (pnotes-graph--node-colour (plist-get meta :tags)))
             (radius (min 20.0 (+ 10.0 (* 2.0 (gethash rel in-deg 0))))))
        (push (list :id rel :colour colour :radius radius :label title) nodes)))
    (maphash (lambda (pair _v)
               (when (or (null visited)
                         (and (gethash (car pair) visited)
                              (gethash (cdr pair) visited)))
                 (push pair edges)))
             edge-set)
    (setq edges (sort edges #'value<))
    (list :nodes (nreverse nodes) :edges edges)))

(defun pnotes-graph--on-node-clicked (node-id)
  "Open the note identified by NODE-ID in a primary editing window."
  (when-let* ((root (pnotes-project-root))
              (target-file (and (stringp node-id)
                                (expand-file-name node-id root))))
    (let* ((graph-win (get-buffer-window (current-buffer)))
           (main-win (pnotes--main-window graph-win)))
      (run-at-time
       0 nil
       (lambda (win r file)
         (when (window-live-p win)
           (select-window win))
         (pnotes--open-note r file 'follow))
       main-win root target-file))))

(defun pnotes-graph--cleanup ()
  "Stop `graph-fa2' playback and kill its playback buffer."
  (graph-fa2-player-stop)
  (when (buffer-live-p graph-fa2-playback-buffer)
    (kill-buffer graph-fa2-playback-buffer)))

(defun pnotes-graph--stop-active-players ()
  "Stop active `graph-fa2' playback in all `pnotes-graph-mode' buffers."
  (dolist (buf (buffer-list))
    (when (buffer-local-value 'pnotes-graph-mode buf)
      (with-current-buffer buf
        (graph-fa2-player-stop)))))

(defun pnotes-graph--launch (buf)
  "Populate and start `graph-fa2' simulation in graph buffer BUF."
  (pnotes-graph--stop-active-players)
  (with-current-buffer buf
    (let* ((root (pnotes-project-root))
           (cache (pnotes--ensure-cache root))
           (data (pnotes-graph--prepare-data cache pnotes-graph--center pnotes-graph--max-hops))
           (cache-dir (pnotes-graph--cache-dir root)))
      (graph-fa2-start buf (plist-get data :nodes) (plist-get data :edges)
                       :cache-dir cache-dir))))

(defun pnotes-graph-refresh ()
  "Reconcile the project cache and restart the `graph-fa2' simulation."
  (interactive)
  (pnotes-cache-reconcile (pnotes--require-root))
  (pnotes-graph--launch (current-buffer)))

(defun pnotes-graph-close ()
  "Close the `pnotes-graph' side window and kill its buffer."
  (interactive)
  (let ((buf (current-buffer)))
    (dolist (win (get-buffer-window-list buf nil t))
      (unless (one-window-p t (window-frame win))
        (set-window-dedicated-p win nil)
        (delete-window win)))
    (kill-buffer buf)))

(defvar-keymap pnotes-graph-mode-map
  :doc "Keymap for `pnotes-graph-mode'."
  "g" #'pnotes-graph-refresh
  "q" #'pnotes-graph-close)

(define-minor-mode pnotes-graph-mode
  "Buffer-local minor mode for `pnotes' force-directed graphs."
  :init-value nil
  :lighter " PNotes-Graph"
  :keymap pnotes-graph-mode-map
  (if pnotes-graph-mode
      (progn
        (setq-local cursor-type nil
                    bidi-display-reordering nil
                    track-mouse 'all
                    display-line-numbers nil
                    left-margin-width 0
                    right-margin-width 0
                    left-fringe-width 0
                    right-fringe-width 0)
        (when-let* ((win (get-buffer-window (current-buffer) t)))
          (set-window-margins win 0 0)
          (set-window-fringes win 0 0))
        (when pnotes-graph--bg-cookie
          (face-remap-remove-relative pnotes-graph--bg-cookie))
        (setq-local pnotes-graph--bg-cookie
                    (face-remap-add-relative 'default :background pnotes-graph-bg-color))
        (add-hook 'kill-buffer-hook #'pnotes-graph--cleanup nil t)
        (add-hook 'graph-fa2-node-clicked-functions #'pnotes-graph--on-node-clicked nil t))
    (when pnotes-graph--bg-cookie
      (face-remap-remove-relative pnotes-graph--bg-cookie)
      (setq-local pnotes-graph--bg-cookie nil))
    (dolist (var '(track-mouse cursor-type bidi-display-reordering
                               display-line-numbers left-margin-width right-margin-width
                               left-fringe-width right-fringe-width))
      (kill-local-variable var))
    (remove-hook 'kill-buffer-hook #'pnotes-graph--cleanup t)
    (remove-hook 'graph-fa2-node-clicked-functions #'pnotes-graph--on-node-clicked t)))

;;;###autoload
(defun pnotes-graph (&optional max-distance)
  "Display the project note graph in a docked side window using `graph-fa2'.
With numeric prefix argument MAX-DISTANCE, display a local graph up to
MAX-DISTANCE hops from the current note.  A prefix of 0 forces a full graph."
  (interactive "P")
  (unless (or (featurep 'graph-fa2) (require 'graph-fa2 nil t))
    (user-error "Package `graph-fa2' is not available"))
  (let* ((root (pnotes--require-root))
         (file (buffer-file-name))
         (center-rel (and file (pnotes--rel-path file root)))
         (max-hops (if (null max-distance)
                       pnotes-graph-max-distance
                     (let ((n (prefix-numeric-value max-distance)))
                       (when (> n 0) n))))
         (repo (file-name-nondirectory (directory-file-name root)))
         (buf (get-buffer-create (format "*pnotes-graph: %s*" repo))))
    (with-current-buffer buf
      (setq-local default-directory root)
      (setq-local pnotes-graph--center center-rel)
      (setq-local pnotes-graph--max-hops max-hops))
    (let ((win (display-buffer-in-side-window
                buf
                '((side . right)
                  (slot . 0)
                  (window-width . 80)
                  (window-parameters . ((no-other-window . nil)
                                        (no-delete-other-windows . t)))))))
      (with-current-buffer buf
        (pnotes-graph-mode 1))
      (when (window-live-p win)
        (window-preserve-size win t t)
        (set-window-dedicated-p win t)))
    (pnotes-graph--launch buf)
    buf))

(provide 'pnotes-graph)
;;; pnotes-graph.el ends here
