;;; pnotes-speedbar.el --- Speedbar tree and overview sidebars for pnotes -*- lexical-binding: t; -*-

;;; Commentary:

;; Adds "PNotes" and "PNotes Overview" display modes to Emacs's built-in
;; `speedbar' library, backed by `pnotes.el''s incremental project cache.

;;; Code:

(require 'pnotes)
(require 'speedbar)
(require 'imenu)

(defcustom pnotes-speedbar-icons t
  "When non-nil, render Nerd Font icons in `pnotes' Speedbar views."
  :type 'boolean
  :group 'pnotes)

(defvar-local pnotes-speedbar--expanded nil
  "Buffer-local map of expanded directory paths and overview folder keys.")

(defvar-local pnotes-speedbar--project-root nil
  "Buffer-local canonical project root displayed in this frame's Speedbar.")

(defun pnotes-speedbar--children (cache rel-dir)
  "Return cons (SUBDIRS . FILES) of immediate children under REL-DIR in CACHE.
REL-DIR is \"\" for project root or a relative directory path ending with \"/\"."
  (let ((prefix-len (length rel-dir))
        dirs files)
    (maphash
     (lambda (rel _meta)
       (when (string-prefix-p rel-dir rel)
         (let* ((rest (substring rel prefix-len))
                (slash (string-search "/" rest)))
           (if slash
               (cl-pushnew (concat rel-dir (substring rest 0 (1+ slash)))
                           dirs :test #'string=)
             (push rel files)))))
     (pnotes--cache-files cache))
    (cons (sort dirs #'string<) (sort files #'string<))))

(defun pnotes-speedbar--buffer (&optional frame)
  "Return the live Speedbar buffer for FRAME (default `selected-frame'), or nil."
  (let ((buf (frame-parameter frame 'pnotes-speedbar-buffer)))
    (and (buffer-live-p buf) buf)))

(defun pnotes-speedbar--visible-p (&optional pnotes-only frame)
  "Return the live Speedbar window on FRAME (default `selected-frame'), or nil.
When PNOTES-ONLY is non-nil, require a PNotes Speedbar display mode."
  (when-let* ((buf (pnotes-speedbar--buffer frame))
              (win (get-buffer-window buf frame))
              ((or (not pnotes-only)
                   (member (buffer-local-value
                            'speedbar-initial-expansion-list-name buf)
                           '("PNotes" "PNotes Overview")))))
    win))

(defun pnotes-speedbar--active-window ()
  "Return the primary editing window on the Speedbar buffer's frame."
  (let* ((sb-win (get-buffer-window (current-buffer) 0))
         (frame (if sb-win (window-frame sb-win) (selected-frame))))
    (pnotes--main-window (pnotes-speedbar--visible-p nil frame) frame)))

(defun pnotes-speedbar--select-main-window ()
  "Select the primary editing window on the Speedbar buffer's frame."
  (let* ((main-win (pnotes-speedbar--active-window))
         (win-frame (window-frame main-win)))
    (unless (eq win-frame (selected-frame))
      (select-frame-set-input-focus win-frame))
    (select-window main-win)))

(defun pnotes-speedbar--active-buffer ()
  "Return the active file-backed `pnotes-mode' buffer for the Speedbar project."
  (let* ((root pnotes-speedbar--project-root)
         (win-buf (window-buffer (pnotes-speedbar--active-window)))
         (match-p (lambda (b)
                    (and (buffer-file-name b)
                         (buffer-local-value 'pnotes-mode b)
                         (with-current-buffer b
                           (equal (pnotes-project-root) root))))))
    (if (funcall match-p win-buf)
        win-buf
      (cl-find-if match-p (buffer-list)))))

(defun pnotes-speedbar--refresh-preserving-line (&optional buf)
  "Redraw frame Speedbar buffer BUF while keeping point near the current line."
  (when-let* ((target (or buf (pnotes-speedbar--buffer))))
    (with-current-buffer target
      (let ((line (line-number-at-pos)))
        (speedbar-update-contents)
        (goto-char (point-min))
        (forward-line (1- line))
        (when-let* ((win (get-buffer-window target 0)))
          (set-window-point win (point)))))))

(defun pnotes-speedbar--dispatch (_text fn _indent)
  "Invoke zero-argument button action closure FN."
  (funcall fn))

(defun pnotes-speedbar--main-action (fn)
  "Return a button action closure that selects the main window and calls FN."
  (lambda ()
    (pnotes-speedbar--select-main-window)
    (funcall fn)))

(defun pnotes-speedbar--btn (text face action)
  "Return propertized Speedbar button string for TEXT invoking ACTION."
  (let ((clean (substring-no-properties text)))
    (propertize clean
                'face face
                'mouse-face 'highlight
                'speedbar-text clean
                'speedbar-function #'pnotes-speedbar--dispatch
                'speedbar-token action
                'rear-nonsticky t)))

(defun pnotes-speedbar--line (depth indent icon icon-face label label-face action)
  "Format a single Speedbar line at DEPTH and INDENT."
  (concat (propertize (format "%d:" depth) 'invisible t)
          (make-string indent ?\s)
          (pnotes-speedbar--btn icon icon-face action)
          " "
          (pnotes-speedbar--btn label label-face action)))

(defun pnotes-speedbar--dir-icon (expanded)
  "Return icon string for a directory or overview folder given EXPANDED."
  (if pnotes-speedbar-icons
      (if expanded "▾ \uf115" "▸ \uf114")
    (if expanded "[-]" "[+]")))

(defun pnotes-speedbar--serialize (node &optional depth)
  "Recursively serialise DOM NODE at DEPTH into a list of line strings."
  (let ((d (or depth 0)))
    (pcase node
      ((pred stringp) (list node))
      (`(:item ,label ,action . ,rest)
       (pcase-let ((`(,selected ,indent) rest))
         (list (pnotes-speedbar--line
                d (or indent (* d 2))
                (if pnotes-speedbar-icons "  \ue612" " ? ") 'speedbar-file-face
                label (if selected 'speedbar-selected-face 'speedbar-file-face)
                (pnotes-speedbar--main-action action)))))
      (`(:folder ,label ,key ,default ,count ,empty-msg ,children)
       (let ((exp (gethash key pnotes-speedbar--expanded default)))
         (cons (pnotes-speedbar--line
                d (* d 2)
                (pnotes-speedbar--dir-icon exp) 'speedbar-button-face
                (format "%s (%d)" label count) 'speedbar-directory-face
                (lambda ()
                  (puthash key (not exp) pnotes-speedbar--expanded)
                  (pnotes-speedbar--refresh-preserving-line)))
               (when exp
                 (let ((kids (funcall children)))
                   (if kids
                       (mapcan (lambda (c) (pnotes-speedbar--serialize c (1+ d))) kids)
                     (and empty-msg (list empty-msg)))))))))))

(defun pnotes-speedbar--render (title dom-nodes)
  "Serialise DOM-NODES under TITLE into `speedbar-buffer' in a single pass."
  (speedbar-with-writable
    (erase-buffer)
    (setq-local header-line-format nil)
    (insert (string-join
             (cons (propertize title 'face 'bold)
                   (mapcan #'pnotes-speedbar--serialize dom-nodes))
             "\n")
            "\n")))

(defun pnotes-speedbar--dir-dom (cache root rel-dir active-file &optional children)
  "Build DOM nodes for directory entries under REL-DIR in CACHE."
  (pcase-let ((`(,dirs . ,files) (or children (pnotes-speedbar--children cache rel-dir))))
    (nconc
     (mapcar
      (lambda (sub-rel)
        (let* ((abs-dir (file-name-as-directory (expand-file-name sub-rel root)))
               (sub-kids (pnotes-speedbar--children cache sub-rel))
               (count (+ (length (car sub-kids)) (length (cdr sub-kids))))
               (name (file-name-nondirectory (directory-file-name sub-rel))))
          `(:folder ,name ,abs-dir nil ,count nil
                    ,(lambda ()
                       (pnotes-speedbar--dir-dom cache root sub-rel active-file sub-kids)))))
      dirs)
     (mapcar
      (lambda (file-rel)
        (let ((abs-path (expand-file-name file-rel root))
              (label (file-name-sans-extension (file-name-nondirectory file-rel))))
          `(:item ,label
                  ,(lambda () (pnotes--open-note root abs-path 'follow))
                  ,(and active-file (string= abs-path active-file)))))
      files))))

(defun pnotes-speedbar-buttons (_directory _zero)
  "Render the \"PNotes\" project note tree inside `speedbar-buffer'."
  (let* ((root pnotes-speedbar--project-root)
         (win-file (buffer-file-name (window-buffer (pnotes-speedbar--active-window)))))
    (pnotes-speedbar--render
     " PNotes"
     (pnotes-speedbar--dir-dom (pnotes--ensure-cache root) root ""
                               (and win-file (expand-file-name win-file))))))

(defun pnotes-speedbar--flatten-imenu (alist &optional level)
  "Flatten imenu ALIST into a list of (LABEL POS LEVEL) entries."
  (let ((lvl (or level 1))
        items)
    (dolist (entry alist (nreverse items))
      (when (and (consp entry) (stringp (car entry))
                 (not (member (car entry) '("*Rescan*" "*Map*"))))
        (let ((label (substring-no-properties (car entry)))
              (target (cdr entry)))
          (cond
           ((or (number-or-marker-p target)
                (and (consp target) (number-or-marker-p (car target))))
            (push (list label (if (consp target) (car target) target) lvl) items))
           ((consp target)
            (let ((self (assoc (car entry) target)))
              (when self
                (push (list label (cdr self) lvl) items))
              (dolist (sub (pnotes-speedbar--flatten-imenu
                            (remq self target) (1+ lvl)))
                (push sub items))))))))))

(defun pnotes-speedbar--section-dom (name default items item-fn)
  "Build an overview `:folder' DOM node for NAME from ITEMS using ITEM-FN."
  `(:folder ,name ,(concat "overview:" name) ,default ,(length items)
            ,(format "  (no %s)" (downcase name))
            ,(lambda () (mapcar item-fn items))))

(defun pnotes-speedbar-overview-buttons (_directory _zero)
  "Render the \"PNotes Overview\" sidebar inside `speedbar-buffer'."
  (let* ((root pnotes-speedbar--project-root)
         (cache (pnotes--ensure-cache root))
         (files-tbl (pnotes--cache-files cache))
         (buf (pnotes-speedbar--active-buffer))
         (file (and buf (buffer-file-name buf)))
         (rel (and file (pnotes--rel-path file root)))
         (meta (and rel (gethash rel files-tbl)))
         (outline (when buf
                    (with-current-buffer buf
                      (ignore-errors
                        (pnotes-speedbar--flatten-imenu
                         (imenu--make-index-alist t))))))
         (tags (or (plist-get meta :tags) (pnotes--all-tags cache)))
         (links (mapcar #'car (plist-get meta :links)))
         (backlinks (when rel (pnotes--backlinks-for-file root rel))))
    (pnotes-speedbar--render
     " PNotes Overview"
     (list
      (pnotes-speedbar--section-dom
       "Outline" t outline
       (lambda (item)
         (pcase-let ((`(,label ,pos ,lvl) item))
           `(:item ,label
                   ,(lambda ()
                      (when (buffer-live-p buf)
                        (switch-to-buffer buf) (goto-char pos) (recenter)))
                   nil ,(+ 2 (* (max 0 (1- lvl)) 2))))))
      (pnotes-speedbar--section-dom
       "Tags" nil tags
       (lambda (tag)
         `(:item ,(concat "#" tag) ,(lambda () (pnotes-search-tag tag root)))))
      (pnotes-speedbar--section-dom
       "Links" t links
       (lambda (link)
         `(:item ,link
                 ,(lambda ()
                    (when (buffer-live-p buf)
                      (switch-to-buffer buf) (pnotes-follow link))))))
      (pnotes-speedbar--section-dom
       "Backlinks" nil backlinks
       (lambda (item)
         (let* ((loc (xref-item-location item))
                (src-file (xref-file-location-file loc))
                (line (xref-file-location-line loc))
                (src-rel (pnotes--rel-path src-file root))
                (title (plist-get (and src-rel (gethash src-rel files-tbl)) :title)))
           `(:item ,(format "%s:%d" title line)
                   ,(lambda ()
                      (pnotes--open-note root src-file 'follow)
                      (goto-char (point-min)) (forward-line (1- line)) (recenter))))))))))

(defun pnotes-speedbar-activate-line ()
  "Activate the Speedbar button on the current line."
  (interactive)
  (unless (get-text-property (point) 'speedbar-function)
    (when-let* ((pos (next-single-property-change
                      (line-beginning-position) 'speedbar-function
                      nil (line-end-position))))
      (goto-char pos)))
  (speedbar-edit-line))

(defun pnotes-speedbar--set-mode (buf mode)
  "Switch frame Speedbar buffer BUF to display MODE and redraw it."
  (with-current-buffer buf
    (setq speedbar-previously-used-expansion-list-name
          speedbar-initial-expansion-list-name
          speedbar-initial-expansion-list-name mode)
    (speedbar-update-contents)
    (speedbar-set-mode-line-format)))

(defun pnotes-speedbar-cycle-mode ()
  "Flip the current frame's Speedbar between \"PNotes\" and \"PNotes Overview\"."
  (interactive)
  (when-let* ((buf (pnotes-speedbar--buffer)))
    (pnotes-speedbar--set-mode
     buf
     (if (string= (buffer-local-value 'speedbar-initial-expansion-list-name buf)
                  "PNotes")
         "PNotes Overview"
       "PNotes"))))

(defun pnotes-speedbar-refresh ()
  "Reconcile the project cache and refresh the current frame's Speedbar view."
  (interactive)
  (when-let* ((buf (pnotes-speedbar--buffer)))
    (with-current-buffer buf
      (when pnotes-speedbar--project-root
        (pnotes-cache-reconcile pnotes-speedbar--project-root))
      (speedbar-update-contents))))

(defun pnotes-speedbar--on-navigation (root _file _event)
  "Refresh the selected frame's Speedbar when navigating notes."
  (when-let* ((win (pnotes-speedbar--visible-p t))
              (buf (window-buffer win)))
    (with-current-buffer buf
      (unless (equal root pnotes-speedbar--project-root)
        (setq-local default-directory root
                    pnotes-speedbar--project-root root
                    speedbar-shown-directories nil
                    speedbar-full-text-cache nil))
      (pnotes-speedbar--refresh-preserving-line buf))))

(defun pnotes-speedbar--unsubscribe ()
  "Remove `pnotes-speedbar--on-navigation' when no frame Speedbar buffers remain."
  (unless (cl-some (lambda (f)
                     (let ((b (pnotes-speedbar--buffer f)))
                       (and b (not (eq b (current-buffer))))))
                   (frame-list))
    (remove-hook 'pnotes-navigation-hook #'pnotes-speedbar--on-navigation)))

;;;###autoload
(defun pnotes-speedbar-close ()
  "Close the current frame's PNotes Speedbar window and kill its buffer."
  (interactive)
  (when-let* ((buf (pnotes-speedbar--buffer)))
    (when-let* ((win (get-buffer-window buf)))
      (set-window-dedicated-p win nil)
      (unless (one-window-p t)
        (delete-window win)))
    (set-frame-parameter nil 'pnotes-speedbar-buffer nil)
    (kill-buffer buf)))

;;;###autoload
(defun pnotes-speedbar-open (&optional display-mode)
  "Open the current frame's PNotes Speedbar sidebar in DISPLAY-MODE."
  (interactive)
  (let* ((mode (or display-mode "PNotes"))
         (existing (pnotes-speedbar--buffer))
         (root (pnotes--require-root
                (or (pnotes-project-root)
                    (and existing
                         (buffer-local-value 'pnotes-speedbar--project-root existing)))))
         (buf (or existing (generate-new-buffer " *pnotes-speedbar*"))))
    (set-frame-parameter nil 'pnotes-speedbar-buffer buf)
    (pnotes--ensure-cache root)
    (with-current-buffer buf
      (unless existing
        (speedbar-mode)
        (dolist (var '(speedbar-initial-expansion-list-name
                       speedbar-previously-used-expansion-list-name
                       speedbar-mode-functions-list
                       speedbar-shown-directories
                       speedbar-full-text-cache
                       speedbar-desired-buffer
                       speedbar-last-selected-file))
          (make-local-variable var))
        (setq-local speedbar-buffer buf
                    pnotes-speedbar--expanded (make-hash-table :test #'equal)
                    pnotes-current-file-function
                    (lambda ()
                      (and (string= speedbar-initial-expansion-list-name "PNotes Overview")
                           (when-let* ((b (pnotes-speedbar--active-buffer)))
                             (buffer-file-name b))))))
      (unless (equal root pnotes-speedbar--project-root)
        (setq-local default-directory root
                    pnotes-speedbar--project-root root
                    speedbar-shown-directories nil
                    speedbar-full-text-cache nil))
      (unless pnotes-mode (pnotes-mode 1))
      (add-hook 'pnotes-navigation-hook #'pnotes-speedbar--on-navigation)
      (add-hook 'kill-buffer-hook #'pnotes-speedbar--unsubscribe nil t))
    (unless (pnotes-speedbar--visible-p)
      (let ((win (display-buffer-in-side-window
                  buf
                  `((side . left)
                    (slot . 0)
                    (window-width . ,(or (bound-and-true-p speedbar-window-default-width) 30))
                    (window-parameters . ((no-other-window . nil)
                                          (no-delete-other-windows . t)))))))
        (when (window-live-p win)
          (set-window-dedicated-p win t))))
    (pnotes-speedbar--set-mode buf mode)))

;;;###autoload
(defun pnotes-speedbar-toggle ()
  "Toggle the PNotes Speedbar sidebar."
  (interactive)
  (if (pnotes-speedbar--visible-p t)
      (pnotes-speedbar-close)
    (pnotes-speedbar-open "PNotes")))

;;;###autoload
(defun pnotes-speedbar-overview ()
  "Open or switch the PNotes Speedbar sidebar to \"PNotes Overview\"."
  (interactive)
  (pnotes-speedbar-open "PNotes Overview"))

(defvar pnotes-speedbar-menu
  '(["Open / Toggle" pnotes-speedbar-activate-line t]
    ["Cycle Tree / Overview" pnotes-speedbar-cycle-mode t]
    ["Refresh" pnotes-speedbar-refresh t]
    "----"
    ["Close" pnotes-speedbar-close t])
  "Easymenu definition for `pnotes' Speedbar display modes.")

(defvar-keymap pnotes-speedbar-key-map
  :doc "Keymap for `pnotes' Speedbar display modes."
  :parent (speedbar-make-specialized-keymap)
  "RET" #'pnotes-speedbar-activate-line
  "SPC" #'pnotes-speedbar-activate-line
  "TAB" #'pnotes-speedbar-activate-line
  "o" #'pnotes-speedbar-cycle-mode
  "g" #'pnotes-speedbar-refresh
  "q" #'pnotes-speedbar-close)

(pcase-dolist (`(,name . ,fn)
               '(("PNotes" . pnotes-speedbar-buttons)
                 ("PNotes Overview" . pnotes-speedbar-overview-buttons)))
  (setq speedbar-initial-expansion-mode-alist
        (assoc-delete-all name speedbar-initial-expansion-mode-alist))
  (speedbar-add-expansion-list
   (list name 'pnotes-speedbar-menu 'pnotes-speedbar-key-map fn)))

(provide 'pnotes-speedbar)
;;; pnotes-speedbar.el ends here
