;;; pnotes-graph.el --- Force-directed graph view for pnotes via graph-fa2 -*- lexical-binding: t; -*-

;;; Commentary:

;; Renders full or N-hop local project note graphs inside a docked side
;; window using optional `graph-fa2', reading edges and backlink counts
;; directly from `pnotes.el''s incremental session cache.

;;; Code:

(require 'pnotes)
(require 'color)
(require 'face-remap)
(require 'graph-fa2 nil t)

(declare-function graph-fa2-start "graph-fa2" (buf nodes edges &key cache-dir))
(declare-function graph-fa2-player-stop "graph-fa2" ())
(declare-function graph-fa2-clear-cache "graph-fa2" (&optional cache-dir))
(declare-function graph-fa2-ctx-bg-timer "graph-fa2" (cl-x))
(defvar graph-fa2-ctx)
(defvar graph-fa2-playback-buffer)
(defvar graph-fa2-node-clicked-functions)
(defvar graph-fa2-after-render-functions)
(defvar graph-fa2-label-colour)
(defvar graph-fa2-edge-colour)
(defvar graph-fa2-edge-label-colour)
(defvar graph-fa2--scale)
(defvar graph-fa2--pan-x)
(defvar graph-fa2--pan-y)
(defvar graph-fa2--nav-state)
(defvar graph-fa2--drag-context)
(defvar graph-fa2-hovered-node)

(defface pnotes-graph-node
  '((t :inherit pnotes-link))
  "Face whose foreground supplies the default `pnotes-graph' node colour."
  :group 'pnotes)

(defface pnotes-graph-edge
  '((t :inherit shadow))
  "Face whose foreground supplies the `pnotes-graph' edge stroke colour."
  :group 'pnotes)

(defface pnotes-graph-label
  '((t :inherit default))
  "Face whose foreground supplies the `pnotes-graph' node label colour."
  :group 'pnotes)

(defface pnotes-graph-edge-label
  '((t :inherit shadow))
  "Face whose foreground supplies the `pnotes-graph' edge label colour."
  :group 'pnotes)

(defcustom pnotes-graph-bg-color nil
  "Optional background colour for the `pnotes-graph' buffer.
When nil, inherit the active theme's `default' background."
  :type '(choice (const :tag "Theme default" nil) color)
  :group 'pnotes)

(defcustom pnotes-graph-node-color nil
  "Optional default node fill colour for `pnotes-graph'.
When nil, derive the colour from the `pnotes-graph-node' face."
  :type '(choice (const :tag "Theme default" nil) color)
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

(defvar pnotes-graph--theme-timer nil
  "Pending timer to refresh live `pnotes-graph-mode' buffers after theme change.")

(defun pnotes-graph--cache-dir (root &optional center max-hops)
  "Return a cache directory for `graph-fa2-start' under ROOT and scope."
  (let* ((repo (file-name-nondirectory (directory-file-name root)))
         (key (format "%s:%s:%s" root center max-hops))
         (subdir (format "%s-%s" repo (substring (md5 key) 0 8))))
    (expand-file-name subdir pnotes-graph-cache-directory)))

(defun pnotes-graph--hex-colour (colour &optional fallback)
  "Convert COLOUR to a `#RRGGBB' hex string, or return FALLBACK."
  (if-let* (((stringp colour))
            ((not (string-prefix-p "unspecified" colour)))
            (rgb (color-name-to-rgb colour)))
      (apply #'color-rgb-to-hex (append rgb '(2)))
    fallback))

(defun pnotes-graph--face-colour (face &optional fallback)
  "Return the `#RRGGBB' foreground colour of FACE, or FALLBACK."
  (pnotes-graph--hex-colour (face-foreground face nil t) fallback))

(defun pnotes-graph--theme-colours ()
  "Return plist of resolved hex colours for the active theme."
  (list :node (or (pnotes-graph--hex-colour pnotes-graph-node-color)
                  (pnotes-graph--face-colour 'pnotes-graph-node "#89b4fa"))
        :edge (pnotes-graph--face-colour 'pnotes-graph-edge "#585b70")
        :label (pnotes-graph--face-colour 'pnotes-graph-label "#cdd6f4")
        :edge-label (pnotes-graph--face-colour 'pnotes-graph-edge-label "#a6adc8")))

(defun pnotes-graph--node-colour (tags &optional default-colour)
  "Return the hex colour for a note with TAGS, falling back to DEFAULT-COLOUR."
  (or (cl-some (lambda (pair)
                 (when (cl-member (car pair) tags :test #'string-equal-ignore-case)
                   (pnotes-graph--hex-colour (cdr pair) (cdr pair))))
               pnotes-graph-tag-groups)
      default-colour
      (pnotes-graph--hex-colour pnotes-graph-node-color)
      (pnotes-graph--face-colour 'pnotes-graph-node "#89b4fa")))

(defun pnotes-graph--prepare-data (cache &optional center-rel max-hops colours)
  "Build `graph-fa2-start' payload (:nodes NODES :edges EDGES) from CACHE.
Projects link key groups from cached `:links' tuples in `pnotes--cache-files'
and derives node prominence from incoming graph edges.
COLOURS is an optional plist from `pnotes-graph--theme-colours'."
  (let* ((theme (or colours (pnotes-graph--theme-colours)))
         (default-node-colour (plist-get theme :node))
         (edge-colour (plist-get theme :edge))
         (files-tbl (pnotes--cache-files cache))
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
             (colour (pnotes-graph--node-colour (plist-get meta :tags)
                                                default-node-colour))
             (radius (min 20.0 (+ 10.0 (* 2.0 (gethash rel in-deg 0))))))
        (push (list :id rel :colour colour :radius radius :label title) nodes)))
    (maphash (lambda (pair _v)
               (when (or (null visited)
                         (and (gethash (car pair) visited)
                              (gethash (cdr pair) visited)))
                 (push pair edges)))
             edge-set)
    (setq edges (mapcar (lambda (pair)
                          (list :from (car pair) :to (cdr pair)
                                :colour edge-colour))
                        (sort edges #'value<)))
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

(defun pnotes-graph--apply-bg-remap ()
  "Apply or remove `pnotes-graph-bg-color' face remapping in current buffer."
  (when pnotes-graph--bg-cookie
    (face-remap-remove-relative pnotes-graph--bg-cookie)
    (setq-local pnotes-graph--bg-cookie nil))
  (when pnotes-graph-bg-color
    (setq-local pnotes-graph--bg-cookie
                (face-remap-add-relative 'default :background pnotes-graph-bg-color))))

(defun pnotes-graph--ensure-theme-cache (cache-dir colours)
  "Clear stale `graph-fa2' cache in CACHE-DIR when COLOURS have changed."
  (let* ((stamp-file (expand-file-name "pnotes-theme.stamp" cache-dir))
         (sig (prin1-to-string colours))
         (prev (when (file-exists-p stamp-file)
                 (with-temp-buffer
                   (insert-file-contents stamp-file)
                   (buffer-string)))))
    (unless (equal prev sig)
      (when (file-exists-p cache-dir)
        (graph-fa2-clear-cache cache-dir))
      (make-directory cache-dir t)
      (with-temp-file stamp-file
        (insert sig)))))

(defun pnotes-graph--refresh-open-buffers ()
  "Re-apply theme colours and relaunch all live `pnotes-graph-mode' buffers."
  (setq pnotes-graph--theme-timer nil)
  (dolist (buf (buffer-list))
    (when (buffer-local-value 'pnotes-graph-mode buf)
      (with-current-buffer buf
        (pnotes-graph--apply-bg-remap)
        (pnotes-graph--launch buf)))))

(defun pnotes-graph--on-theme-change (&optional _theme)
  "Schedule a debounced theme refresh for live `pnotes-graph-mode' buffers."
  (when (cl-some (lambda (b) (buffer-local-value 'pnotes-graph-mode b))
                 (buffer-list))
    (when (timerp pnotes-graph--theme-timer)
      (cancel-timer pnotes-graph--theme-timer))
    (setq pnotes-graph--theme-timer
          (run-at-time 0 nil #'pnotes-graph--refresh-open-buffers))))

(defun pnotes-graph--maybe-unhook-theme ()
  "Remove theme hooks when no other `pnotes-graph-mode' buffers remain."
  (unless (cl-some (lambda (b)
                     (and (not (eq b (current-buffer)))
                          (buffer-local-value 'pnotes-graph-mode b)))
                   (buffer-list))
    (when (timerp pnotes-graph--theme-timer)
      (cancel-timer pnotes-graph--theme-timer)
      (setq pnotes-graph--theme-timer nil))
    (remove-hook 'enable-theme-functions #'pnotes-graph--on-theme-change)
    (remove-hook 'disable-theme-functions #'pnotes-graph--on-theme-change)))

(defun pnotes-graph--stop-player ()
  "Stop `graph-fa2' playback and any active background worker in current buffer."
  (graph-fa2-player-stop)
  (when-let* ((tmr (and graph-fa2-ctx (graph-fa2-ctx-bg-timer graph-fa2-ctx))))
    (cancel-timer tmr)))

(defun pnotes-graph--cleanup ()
  "Stop `graph-fa2' playback, kill its playback buffer, and unhook theme sync."
  (pnotes-graph--stop-player)
  (when (buffer-live-p graph-fa2-playback-buffer)
    (kill-buffer graph-fa2-playback-buffer))
  (pnotes-graph--maybe-unhook-theme))

(defun pnotes-graph--after-render ()
  "Force repaint of non-selected `pnotes-graph' windows after rendering."
  (when-let* ((win (get-buffer-window (current-buffer) t))
              ((not (eq win (selected-window)))))
    (force-window-update win)))

(defun pnotes-graph--stop-active-players ()
  "Stop active `graph-fa2' playback and background workers in graph buffers."
  (dolist (buf (buffer-list))
    (when (buffer-local-value 'pnotes-graph-mode buf)
      (with-current-buffer buf
        (pnotes-graph--stop-player)))))

(defun pnotes-graph--launch (buf)
  "Populate and start `graph-fa2' simulation in graph buffer BUF."
  (pnotes-graph--stop-active-players)
  (with-current-buffer buf
    (let* ((root (pnotes-project-root))
           (cache (pnotes--ensure-cache root))
           (local-p (and (integerp pnotes-graph--max-hops)
                         (> pnotes-graph--max-hops 0)
                         pnotes-graph--center
                         (gethash pnotes-graph--center (pnotes--cache-files cache))))
           (center (and local-p pnotes-graph--center))
           (hops (and local-p pnotes-graph--max-hops))
           (colours (pnotes-graph--theme-colours))
           (data (pnotes-graph--prepare-data cache center hops colours))
           (cache-dir (pnotes-graph--cache-dir root center hops)))
      (mapc #'delete-overlay (overlays-in (point-min) (point-max)))
      (setq-local graph-fa2--scale 1.0
                  graph-fa2--pan-x 0.0
                  graph-fa2--pan-y 0.0
                  graph-fa2--nav-state 'idle
                  graph-fa2--drag-context nil
                  graph-fa2-hovered-node nil)
      (setq graph-fa2-label-colour (plist-get colours :label)
            graph-fa2-edge-colour (plist-get colours :edge)
            graph-fa2-edge-label-colour (plist-get colours :edge-label))
      (pnotes-graph--ensure-theme-cache cache-dir colours)
      (graph-fa2-start buf (plist-get data :nodes) (plist-get data :edges)
                       :cache-dir cache-dir))))

(defun pnotes-graph-refresh ()
  "Reconcile the project cache and restart the `graph-fa2' simulation."
  (declare (modes pnotes-graph-mode))
  (interactive)
  (unless pnotes-graph-mode
    (user-error "Not in a `pnotes-graph' buffer"))
  (pnotes-cache-reconcile (pnotes--require-root))
  (pnotes-graph--apply-bg-remap)
  (pnotes-graph--launch (current-buffer)))

(defun pnotes-graph-close ()
  "Close the `pnotes-graph' side window and kill its buffer."
  (declare (modes pnotes-graph-mode))
  (interactive)
  (unless pnotes-graph-mode
    (user-error "Not in a `pnotes-graph' buffer"))
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
                    display-line-numbers nil
                    left-margin-width 0
                    right-margin-width 0
                    left-fringe-width 0
                    right-fringe-width 0)
        (pnotes-graph--apply-bg-remap)
        (add-hook 'kill-buffer-hook #'pnotes-graph--cleanup nil t)
        (add-hook 'graph-fa2-node-clicked-functions #'pnotes-graph--on-node-clicked nil t)
        (add-hook 'graph-fa2-after-render-functions #'pnotes-graph--after-render nil t)
        (add-hook 'enable-theme-functions #'pnotes-graph--on-theme-change)
        (add-hook 'disable-theme-functions #'pnotes-graph--on-theme-change))
    (when pnotes-graph--bg-cookie
      (face-remap-remove-relative pnotes-graph--bg-cookie)
      (setq-local pnotes-graph--bg-cookie nil))
    (dolist (var '(cursor-type bidi-display-reordering
                               display-line-numbers left-margin-width right-margin-width
                               left-fringe-width right-fringe-width))
      (kill-local-variable var))
    (remove-hook 'kill-buffer-hook #'pnotes-graph--cleanup t)
    (remove-hook 'graph-fa2-node-clicked-functions #'pnotes-graph--on-node-clicked t)
    (remove-hook 'graph-fa2-after-render-functions #'pnotes-graph--after-render t)
    (pnotes-graph--maybe-unhook-theme)))

;;;###autoload
(defun pnotes-graph (&optional max-distance)
  "Display the project note graph in a docked side window using `graph-fa2'.
With numeric prefix argument MAX-DISTANCE, display a local graph up to
MAX-DISTANCE hops from the current note.  A prefix of 0 forces a full graph."
  (interactive "P")
  (unless (or (featurep 'graph-fa2) (require 'graph-fa2 nil t))
    (user-error "Package `graph-fa2' is not available"))
  (let* ((root (pnotes--require-root))
         (file (pnotes--current-file))
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
        (unless pnotes-graph-mode (pnotes-graph-mode 1)))
      (when (window-live-p win)
        (set-window-margins win 0 0)
        (set-window-fringes win 0 0)
        (window-preserve-size win t t)
        (set-window-dedicated-p win t)))
    (pnotes-graph--launch buf)
    buf))

(provide 'pnotes-graph)
;;; pnotes-graph.el ends here
