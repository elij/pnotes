;;; pnotes.el --- Project-bound note links, cache, and remember capture -*- lexical-binding: t; -*-

;; Author: Elijah Charles
;; Version: 0.0.03
;; Package-Requires: ((emacs "31.0"))
;; Description: Scheme-free project-scoped note engine for Emacs

;;; Commentary:

;; Project-scoped note navigation, generalised link scheme projection,
;; pluggable mode/format adapters, incremental session caching, Capf
;; completion, xref backlinks, and `remember.el' capture.  Optional UI
;; views live in `pnotes-ui.el', `pnotes-speedbar.el', and
;; `pnotes-graph.el'.

;;; Code:

(require 'cl-lib)
(require 'format-spec)
(require 'map)
(require 'project)
(require 'xref)
(require 'remember)
(require 'subr-x)

(autoload 'pnotes "pnotes-ui" nil t)
(autoload 'pnotes-inbox-review "pnotes-ui" nil t)
(autoload 'pnotes-speedbar-toggle "pnotes-speedbar" nil t)
(autoload 'pnotes-speedbar-overview "pnotes-speedbar" nil t)
(autoload 'pnotes-graph "pnotes-graph" nil t)

(declare-function consult-ripgrep "consult" (&optional dir initial))
(defvar consult-ripgrep-args)
(defvar consult-async-split-style)
(defvar pnotes-mode)

;;; Customisation, default schemes, and mode adapters

(defgroup pnotes nil
  "Project-scoped note linking, incremental caching, and capture."
  :group 'text)

(defface pnotes-link
  '((t :inherit link))
  "Face applied to navigable `pnotes' links."
  :group 'pnotes)

(defcustom pnotes-link-schemes
  '((:name org-file
           :prefix "file:"
           :strip-prefix t
           :template "%d/%p.%e"
           :complete-fn pnotes-complete-file-relative
           :extensions ("org" "md")
           :index t)
    (:name relative
           :prefix ("./" "../")
           :template "%d/%p.%e"
           :complete-fn pnotes-complete-file-relative
           :extensions ("md" "org")
           :index t)
    (:name root
           :prefix nil
           :template "%r/%p.%e"
           :complete-fn pnotes-complete-root
           :format-fn pnotes-format-root
           :extensions ("md" "org")
           :index t)
    (:name stem
           :symbolic t
           :project-source filename
           :project-fn file-name-sans-extension
           :normalize-fn file-name-sans-extension
           :extensions ("md" "org")
           :index t)
    (:name title
           :symbolic t
           :project-source meta
           :project-fn (lambda (meta) (plist-get meta :title))
           :extensions ("md" "org")
           :index t))
  "Ordered registry of link resolution and indexing schemes.
Each entry is a plist with keys:
  :name              Symbol naming the scheme.
  :prefix            String, list of strings, or nil for bare scheme.
  :regexp            Optional regexp matched against the cleaned target.
  :strip-prefix      Non-nil to remove the matched prefix before expansion.
  :symbolic          Non-nil for cache-projected symbolic schemes.
  :project-source    Source for symbolic key extraction: `filename', `buffer',
                     or `meta'.
  :project-regexp    Regexp (capture group 1) extracting keys from the source.
  :project-fn        Function extracting key(s) from the source.
  :normalize-fn      Optional fn normalising a target before symbolic lookup.
  :template          `format-spec' template using %r (root), %d (source dir),
                     %p (path), %e (extension), or nil for action-only schemes.
  :create-template   `format-spec' template used when creating an unresolved
                     symbolic note.
  :follow-fn         Function called with link target for action-only schemes,
                     or as fallback when a symbolic cache lookup misses.
  :complete-fn       Function (SCHEME START END PREFIX CLOSE SRC-DIR ROOT)
                     returning a Capf completion spec for this scheme.
  :format-fn         Function (SCHEME REL-PATH META ROOT TARGET-DIR) returning a
                     formatted link target string for REL-PATH, or nil.
  :accept-target-p   Optional predicate (PATH-VAL) deciding whether this scheme
                     claims PATH-VAL for interactive follow handling.
  :extensions        List of file extensions (without dot).  First is default.
  :index             Non-nil to index this scheme in the inverted cache."
  :type '(repeat plist)
  :group 'pnotes)

(defvar pnotes-mode-adapter-org
  '(:name org
          :modes (org-mode)
          :extensions ("org")
          :link-regexp "\\[\\[\\([^]\n]+?\\)\\(?:\\]\\[[^]\n]+\\)?\\]\\]"
          :alias-separator "\\]\\["
          :ignore-regexp "\\`\\*"
          :capf-bounds-specs (("\\[\\[\\([^]\n]*\\)" "]]"))
          :format-link-fn pnotes-adapter-wiki-format-link
          :parse-meta-fn pnotes-adapter-org-parse-meta
          :tag-capf-fn pnotes-adapter-org-tag-capf
          :tag-search-regexp-fn pnotes-adapter-org-tag-search-regexp
          :daily-header-template "#+title: %H\n#+date: %I\n\n")
  "Built-in mode and format adapter for Org buffers and `.org' notes.")

(defvar pnotes-mode-adapter-markdown
  '(:name markdown
          :modes (markdown-mode gfm-mode markdown-ts-mode)
          :extensions ("md" "markdown")
          :link-regexp "\\(?:\\[\\[\\([^]\n]+?\\)\\(?:|[^]\n]+\\)?\\]\\]\\|\\[[^]\n]+\\](\\([^)\n[:space:]]+\\))\\)"
          :link-match-fn pnotes-adapter-markdown-link-match
          :alias-separator "|"
          :capf-bounds-specs (("\\[\\[\\([^]|\n]*\\)" "]]")
                              ("\\[[^]\n]+\\](\\([^)\n[:space:]]*\\)" ")" t))
          :format-link-fn pnotes-adapter-wiki-format-link
          :parse-meta-fn pnotes-adapter-markdown-parse-meta
          :tag-capf-fn pnotes-adapter-markdown-tag-capf
          :tag-search-regexp-fn pnotes-adapter-markdown-tag-search-regexp
          :daily-header-template "---\ndate: %I\n---\n\n# %H\n\n")
  "Built-in mode and format adapter for Markdown buffers and `.md' notes.")

(defvar pnotes-mode-adapter-generic
  (map-merge 'plist
             pnotes-mode-adapter-markdown
             '(:name generic
                     :modes nil
                     :extensions nil
                     :link-regexp "\\[\\[\\([^]\n]+?\\)\\(?:|[^]\n]+\\)?\\]\\]"
                     :link-match-fn nil
                     :capf-bounds-specs (("\\[\\[\\([^]|\n]*\\)" "]]"))))
  "Fallback format adapter for plain-text and unrecognised note formats.")

(defcustom pnotes-mode-adapters
  (list pnotes-mode-adapter-org
        pnotes-mode-adapter-markdown
        pnotes-mode-adapter-generic)
  "Ordered registry of major-mode and document-format adapters.
Each entry is a plist describing how `pnotes' integrates with a major mode
or file format:
  :name                   Symbol naming the adapter.
  :modes                  List of major modes matched with `derived-mode-p'.
  :extensions             File extensions (without dot) for disk parsing.
  :link-regexp            Link regexp (group 1 unless :link-match-fn).
  :link-match-fn          Optional 0-arg fn extracting target from match data.
  :alias-separator        Regexp splitting display aliases from targets.
  :ignore-regexp          Optional regexp for mode-native targets to ignore.
  :capf-bounds-specs      List of (REGEXP CLOSE &optional REJECT-BANG) specs.
  :format-link-fn         Function (TARGET &optional TITLE) returning a link.
  :parse-meta-fn          Function returning plist (:title TITLE :tags TAGS).
  :tag-capf-fn            Function returning tag completion start or nil.
  :tag-search-regexp-fn   Function (CLEAN-TAG) returning a space-free regexp.
  :daily-header-template  `format-spec' template using %H (date) and %I (ISO)."
  :type '(repeat plist)
  :group 'pnotes)

(defcustom pnotes-inbox-directory "inbox"
  "Subdirectory relative to project root used by `pnotes-capture'."
  :type 'string
  :group 'pnotes)

(defcustom pnotes-capture-file-format "%Y-%m-%d_%H-%M-%S"
  "Time format stem for files created via `pnotes-capture'."
  :type 'string
  :group 'pnotes)

(defcustom pnotes-capture-annotate t
  "When non-nil, add a backlink to the originating note on capture."
  :type 'boolean
  :group 'pnotes)

(defcustom pnotes-capture-open-after-save t
  "When non-nil, open the newly saved capture file in `pnotes-mode'."
  :type 'boolean
  :group 'pnotes)

(defcustom pnotes-daily-directory "daily"
  "Subdirectory relative to project root used by `pnotes-daily'."
  :type 'string
  :group 'pnotes)

(defcustom pnotes-daily-format "%Y-%m-%d"
  "Time format string for daily note filename stems."
  :type 'string
  :group 'pnotes)

(defun pnotes-daily-default-header (time path)
  "Return default header text for a new daily note at PATH for TIME.
Expands the matching adapter's `:daily-header-template'."
  (when-let* ((adapter (pnotes--adapter-for-extension
                        (and path (file-name-extension path))))
              (tmpl (plist-get adapter :daily-header-template)))
    (format-spec tmpl
                 `((?H . ,(format-time-string "%A, %-e %B %Y" time))
                   (?I . ,(format-time-string "%Y-%m-%d" time))))))

(defcustom pnotes-daily-header-function #'pnotes-daily-default-header
  "Function returning initial text for a newly created empty daily note.
Called with two arguments, (TIME PATH), and should return a string or nil.
When nil, newly created daily note buffers start blank."
  :type '(choice (const :tag "Blank buffer" nil)
                 (function :tag "Header function"))
  :group 'pnotes)

(defcustom pnotes-navigation-hook nil
  "Abnormal hook run on note lifecycle and navigation events.
Functions receive three arguments: (ROOT FILE EVENT), where EVENT is one of
`follow', `capture', `save', or `switch'."
  :type 'hook
  :group 'pnotes)

;;; Internal state

(defvar pnotes--caches (make-hash-table :test #'equal)
  "Map from canonical project root to `pnotes--cache' struct.")

(defvar pnotes--last-active-file nil
  "Last note file reported by the window-change observer.")

(cl-defstruct pnotes--cache
  files     ; hash: rel-path -> plist (:mtime :title :tags :links :keys :scheme-keys :projections)
  backlinks ; hash: cache-key -> list of referencing source rel-paths
  targets)  ; hash: projected-key -> list of target rel-paths

;;; Project, scheme, and adapter lookup helpers

(defun pnotes-project-root (&optional dir prompt)
  "Return canonical project root for DIR, prompting when PROMPT is non-nil."
  (when-let* ((proj (project-current prompt dir))
              ((not (eq (car-safe proj) 'transient))))
    (file-name-as-directory (expand-file-name (project-root proj)))))

(defun pnotes--require-root (&optional root)
  "Return ROOT or `(pnotes-project-root)', signalling `user-error' if nil."
  (or root (pnotes-project-root)
      (user-error "Not inside a recognised project")))

(defun pnotes--all-extensions ()
  "Return deduplicated list of extensions declared across `pnotes-link-schemes'."
  (cl-delete-duplicates
   (mapcan (lambda (s) (copy-sequence (plist-get s :extensions)))
           pnotes-link-schemes)
   :test #'string-equal-ignore-case :from-end t))

(defun pnotes--bare-scheme-p (scheme &optional symbolic-p)
  "Return non-nil if SCHEME has no `:prefix' or `:regexp' and matches SYMBOLIC-P."
  (and (eq (not (null (plist-get scheme :symbolic))) (not (null symbolic-p)))
       (null (plist-get scheme :prefix))
       (null (plist-get scheme :regexp))))

(defun pnotes--default-extension ()
  "Return default file extension from configured schemes."
  (or (cl-some (lambda (scheme)
                 (and (pnotes--bare-scheme-p scheme)
                      (car (plist-get scheme :extensions))))
               pnotes-link-schemes)
      (car (pnotes--all-extensions))
      "md"))

(defun pnotes--has-extension-p (path extensions)
  "Return non-nil if PATH ends with an extension in EXTENSIONS."
  (when-let* ((ext (file-name-extension path)))
    (member-ignore-case ext extensions)))

(defun pnotes--strip-ext (path ext)
  "Strip EXT from PATH when PATH's extension matches EXT case-insensitively."
  (if (and ext (pnotes--has-extension-p path (list ext)))
      (file-name-sans-extension path)
    path))

(defun pnotes--rel-path (abs-path root)
  "Return project-relative path if ABS-PATH lies inside ROOT, otherwise nil.
Avoids `file-in-directory-p' so uncreated files in new subdirectories work."
  (let ((expanded (expand-file-name abs-path))
        (exp-root (file-name-as-directory (expand-file-name root))))
    (when (string-prefix-p exp-root expanded)
      (file-relative-name expanded exp-root))))

(defun pnotes--main-window (&optional exclude-win frame)
  "Return a primary non-side window on FRAME, avoiding EXCLUDE-WIN."
  (let ((target-frame (and (frame-live-p frame) frame)))
    (or (cl-find-if (lambda (w)
                      (and (not (eq w exclude-win))
                           (null (window-parameter w 'window-side))))
                    (window-list target-frame 'no-minibuf))
        (frame-selected-window target-frame))))

(defun pnotes--adapter-for-extension (ext)
  "Return the first adapter in `pnotes-mode-adapters' matching EXT, or the last."
  (or (and ext
           (cl-find-if (lambda (a)
                         (member-ignore-case ext (plist-get a :extensions)))
                       pnotes-mode-adapters))
      (car (last pnotes-mode-adapters))))

(defun pnotes--buffer-adapter (&optional file)
  "Return the format adapter for the current buffer, or FILE when parsing."
  (let ((fname (or file (buffer-file-name))))
    (or (cl-find-if (lambda (adapter)
                      (apply #'derived-mode-p (plist-get adapter :modes)))
                    pnotes-mode-adapters)
        (pnotes--adapter-for-extension
         (if fname (file-name-extension fname) (pnotes--default-extension))))))

;;; Adapter dispatch helpers

(defun pnotes--adapter-scan-region (adapter beg end)
  "Scan BEG..END for links using ADAPTER, returning (TARGET BEG . END) items."
  (when-let* ((re (plist-get adapter :link-regexp)))
    (let ((match-fn (plist-get adapter :link-match-fn))
          items)
      (goto-char beg)
      (while (re-search-forward re end t)
        (let ((mb (match-beginning 0))
              (me (match-end 0)))
          (when-let* ((raw (if match-fn (funcall match-fn) (match-string-no-properties 1)))
                      (target (pnotes--clean-target raw adapter)))
            (push (cons target (cons mb me)) items))))
      (nreverse items))))

;;; Link matching and generalised scheme resolution

(defun pnotes--scheme-matched-prefix (scheme target)
  "Return the matched prefix string of SCHEME for TARGET, or nil."
  (cl-find-if (lambda (p) (string-prefix-p p target))
              (ensure-list (plist-get scheme :prefix))))

(defun pnotes--stripped-prefix (scheme &optional target)
  "Return matched (or first) prefix of SCHEME when `:strip-prefix' is set, else \"\"."
  (or (and (plist-get scheme :strip-prefix)
           (if target
               (pnotes--scheme-matched-prefix scheme target)
             (car (ensure-list (plist-get scheme :prefix)))))
      ""))

(defun pnotes--match-scheme (target)
  "Find the first matching scheme for TARGET.
Matches regexp schemes, prefixed schemes (including prefixed symbolic ones),
and the first bare non-symbolic fallback scheme.  Returns (SCHEME . PATH-VAL)."
  (cl-some
   (lambda (scheme)
     (let ((re (plist-get scheme :regexp))
           (prefix (plist-get scheme :prefix)))
       (cond
        (re (when (string-match-p re target) (cons scheme target)))
        (prefix
         (when-let* ((matched (pnotes--scheme-matched-prefix scheme target)))
           (cons scheme (if (plist-get scheme :strip-prefix)
                            (string-remove-prefix matched target)
                          target))))
        ((and (not (plist-get scheme :symbolic))
              (not (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*:" target)))
         (cons scheme target)))))
   pnotes-link-schemes))

(defun pnotes--clean-target (raw &optional adapter)
  "Strip display aliases and `#fragment' suffixes from RAW using ADAPTER.
Return nil if the resulting target is empty or matches `:ignore-regexp'."
  (when-let* ((raw)
              (ad (or adapter (pnotes--buffer-adapter)))
              (stripped (if-let* ((sep (plist-get ad :alias-separator)))
                            (car (split-string raw sep))
                          raw))
              (cleaned (string-trim (car (split-string stripped "#"))))
              ((not (string-empty-p cleaned)))
              ((not (when-let* ((re (plist-get ad :ignore-regexp)))
                      (string-match-p re cleaned)))))
    cleaned))

(defun pnotes--link-at-point ()
  "Return cleaned link target under point, or nil."
  (or (get-text-property (point) 'pnotes-link-target)
      (when-let* ((adapter (pnotes--buffer-adapter)))
        (let ((pt (point)))
          (save-excursion
            (cl-some (lambda (item)
                       (pcase-let ((`(,target ,beg . ,end) item))
                         (when (<= beg pt end) target)))
                     (pnotes--adapter-scan-region
                      adapter (line-beginning-position) (line-end-position))))))))

(defun pnotes--expand-template (template path-val source-dir root &optional ext)
  "Expand `format-spec' TEMPLATE using PATH-VAL, SOURCE-DIR, ROOT, and EXT.
Return nil if PATH-VAL is absolute or resolves outside ROOT."
  (unless (file-name-absolute-p path-val)
    (let* ((tmpl (if ext template (replace-regexp-in-string "\\.%e" "" template t t)))
           (spec `((?r . ,(directory-file-name (expand-file-name root)))
                   (?d . ,(directory-file-name (expand-file-name source-dir)))
                   (?p . ,path-val)
                   (?e . ,(or ext ""))))
           (abs (expand-file-name (format-spec tmpl spec))))
      (when (pnotes--rel-path abs root)
        abs))))

(defun pnotes--note-target-p (target)
  "Return non-nil if cleaned TARGET should be handled by `pnotes'."
  (when-let* ((matched (pnotes--match-scheme target)))
    (pcase-let* ((`(,scheme . ,path-val) matched)
                 (tmpl (plist-get scheme :template))
                 (exts (plist-get scheme :extensions)))
      (cond
       ((plist-get scheme :accept-target-p)
        (funcall (plist-get scheme :accept-target-p) path-val))
       ((or (plist-get scheme :symbolic)
            (and (null tmpl) (plist-get scheme :follow-fn)))
        t)
       ((stringp tmpl)
        (when-let* ((root (pnotes-project-root))
                    (abs (pnotes--expand-template tmpl path-val default-directory root nil)))
          (not (and exts
                    (file-name-extension path-val)
                    (not (pnotes--has-extension-p path-val exts))
                    (file-exists-p abs)))))))))

(defun pnotes--scheme-key (scheme raw-key &optional normalize-p)
  "Format canonical inverted index key for SCHEME and RAW-KEY.
When NORMALIZE-P is non-nil, apply SCHEME's `:normalize-fn' to RAW-KEY."
  (let ((fn (and normalize-p (plist-get scheme :normalize-fn))))
    (format "%s:%s" (plist-get scheme :name)
            (downcase (if fn (funcall fn raw-key) raw-key)))))

(defun pnotes--extract-scheme-values (scheme &optional source-val buffer-p)
  "Extract non-empty key strings for SCHEME from SOURCE-VAL (or buffer if BUFFER-P)."
  (let ((fn (plist-get scheme :project-fn))
        (re (plist-get scheme :project-regexp)))
    (delete-dups
     (cl-remove-if-not
      (lambda (s) (and (stringp s) (not (string-empty-p s))))
      (ensure-list
       (if buffer-p
           (if fn (funcall fn)
             (when re
               (goto-char (point-min))
               (cl-loop while (re-search-forward re nil t)
                        collect (match-string-no-properties 1))))
         (if fn (and source-val (funcall fn source-val))
           (and re (stringp source-val) (string-match re source-val)
                (match-string 1 source-val)))))))))

(defun pnotes--scheme-file-values (scheme rel-path meta)
  "Return raw projected string values for SCHEME from REL-PATH and META."
  (when (pnotes--has-extension-p rel-path (plist-get scheme :extensions))
    (pcase (plist-get scheme :project-source)
      ('filename (pnotes--extract-scheme-values scheme (file-name-nondirectory rel-path)))
      ('meta     (pnotes--extract-scheme-values scheme meta))
      ('buffer   (alist-get (plist-get scheme :name) (plist-get meta :scheme-keys))))))

(defun pnotes--target-symbolic-schemes (scheme path-val)
  "Return symbolic schemes applicable to SCHEME and PATH-VAL."
  (cond
   ((plist-get scheme :symbolic) (list scheme))
   ((and (pnotes--bare-scheme-p scheme) (not (string-search "/" path-val)))
    (cl-remove-if-not (lambda (s) (pnotes--bare-scheme-p s t))
                      pnotes-link-schemes))))

(defun pnotes--collect-targets (keys cache)
  "Return deduplicated target rel-paths in CACHE for KEYS."
  (let ((targets-tbl (pnotes--cache-targets cache)))
    (delete-dups
     (mapcan (lambda (k) (copy-sequence (gethash k targets-tbl))) keys))))

(defun pnotes-resolve (raw-target &optional source-dir root interactive-p)
  "Resolve RAW-TARGET using `pnotes-link-schemes' within the project root.
SOURCE-DIR defaults to `default-directory'; ROOT defaults to the project root.
When INTERACTIVE-P is non-nil, prompt on ambiguous symbolic matches.
Returns a plist (:kind :scheme :path :rel :exists ...), or nil."
  (when-let* ((target (pnotes--clean-target raw-target))
              (matched (pnotes--match-scheme target))
              (src-dir (or source-dir default-directory))
              (proj-root (or root (pnotes-project-root src-dir))))
    (pcase-let* ((`(,scheme . ,path-val) matched)
                 (scheme-name (plist-get scheme :name))
                 (tmpl (plist-get scheme :template))
                 (exts (plist-get scheme :extensions))
                 (has-ext (pnotes--has-extension-p path-val exts))
                 (sym-schemes (pnotes--target-symbolic-schemes scheme path-val))
                 (file-res (lambda (abs sname exists)
                             (list :kind 'file :scheme sname :path abs
                                   :rel (file-relative-name abs proj-root)
                                   :exists exists))))
      (or (when (stringp tmpl)
            (cl-some (lambda (ext)
                       (when-let* ((cand (pnotes--expand-template
                                          tmpl path-val src-dir proj-root ext))
                                   ((file-regular-p cand)))
                         (funcall file-res cand scheme-name t)))
                     (if (or has-ext (not (string-search "%e" tmpl))) '(nil) exts)))
          (when-let* ((sym-schemes)
                      (keys (mapcar (lambda (s) (pnotes--scheme-key s path-val t))
                                    sym-schemes))
                      (matches (pnotes--collect-targets
                                keys (pnotes--ensure-cache proj-root)))
                      (choice (cond
                               ((length= matches 1) (car matches))
                               ((and (length> matches 1) interactive-p)
                                (completing-read
                                 (format "Multiple matches for \"%s\": " path-val)
                                 matches nil t)))))
            (funcall file-res (expand-file-name choice proj-root)
                     (if (plist-get scheme :symbolic) scheme-name 'symbolic) t))
          (when-let* ((fn (plist-get scheme :follow-fn)))
            (list :kind 'follow-fn :scheme scheme-name :fn fn :path path-val :exists t))
          (when-let* ((create-tmpl (or (plist-get scheme :create-template) tmpl))
                      (abs (pnotes--expand-template
                            create-tmpl path-val src-dir proj-root
                            (unless has-ext (car exts)))))
            (funcall file-res abs scheme-name nil))))))

;;; Generalised cache keys and projections

(defun pnotes--file-projections (rel-path meta)
  "Return deduplicated list of cache keys exposed by REL-PATH with META."
  (let ((rel-no-ext (file-name-sans-extension rel-path))
        path-done bare-done keys)
    (dolist (scheme pnotes-link-schemes (nreverse keys))
      (when (and (plist-get scheme :index)
                 (pnotes--has-extension-p rel-path (plist-get scheme :extensions)))
        (let ((tmpl (plist-get scheme :template)))
          (cond
           ((stringp tmpl)
            (unless path-done
              (setq path-done t)
              (push (concat "path:" rel-path) keys))
            (when (and (not bare-done) (string-search "%e" tmpl))
              (setq bare-done t)
              (push (concat "path-bare:" rel-no-ext) keys)))
           ((plist-get scheme :symbolic)
            (dolist (val (pnotes--scheme-file-values scheme rel-path meta))
              (cl-pushnew (pnotes--scheme-key scheme val) keys :test #'string=)))))))))

(defun pnotes--link-keys (target source-dir root)
  "Return deduplicated list of inverted backlink keys emitted by cleaned TARGET."
  (when-let* ((target)
              (matched (pnotes--match-scheme target)))
    (pcase-let* ((`(,scheme . ,path-val) matched)
                 (tmpl (plist-get scheme :template))
                 (exts (plist-get scheme :extensions))
                 (has-ext (pnotes--has-extension-p path-val exts))
                 (keys nil))
      (when-let* (((plist-get scheme :index))
                  ((stringp tmpl))
                  (expanded (pnotes--expand-template
                             tmpl path-val source-dir root (unless has-ext (car exts)))))
        (let ((rel (file-relative-name expanded root)))
          (push (if has-ext
                    (concat "path:" rel)
                  (concat "path-bare:" (file-name-sans-extension rel)))
                keys)))
      (dolist (sym (pnotes--target-symbolic-schemes scheme path-val) (nreverse keys))
        (when (plist-get sym :index)
          (cl-pushnew (pnotes--scheme-key sym path-val t) keys :test #'string=))))))

(defun pnotes-cache-resolve-link-group (keys cache)
  "Resolve cached link key group KEYS against CACHE in memory.
Checks a leading direct path key first, falling back to symbolic keys
only when no path key matches."
  (when keys
    (if (or (string-prefix-p "path:" (car keys))
            (string-prefix-p "path-bare:" (car keys)))
        (or (copy-sequence (gethash (car keys) (pnotes--cache-targets cache)))
            (pnotes--collect-targets (cdr keys) cache))
      (pnotes--collect-targets keys cache))))

;;; Parsing and incremental session cache

(defun pnotes--parse-buffer (file root)
  "Parse metadata, link tuples, and scheme keys from buffer for FILE in ROOT."
  (let* ((source-dir (file-name-directory file))
         (adapter (pnotes--buffer-adapter file))
         title tags links scheme-keys)
    (save-excursion
      (save-restriction
        (widen)
        (when-let* ((meta-fn (plist-get adapter :parse-meta-fn))
                    (parsed (funcall meta-fn)))
          (setq title (plist-get parsed :title)
                tags (plist-get parsed :tags)))
        (dolist (s pnotes-link-schemes)
          (when-let* (((plist-get s :symbolic))
                      ((plist-get s :index))
                      ((eq (plist-get s :project-source) 'buffer))
                      (vals (pnotes--extract-scheme-values s nil t)))
            (push (cons (plist-get s :name) vals) scheme-keys)))
        (pcase-dolist (`(,target ,beg . ,_end)
                       (pnotes--adapter-scan-region adapter (point-min) (point-max)))
          (goto-char beg)
          (push (list target
                      (pnotes--link-keys target source-dir root)
                      (line-number-at-pos)
                      (- beg (line-beginning-position))
                      (string-trim (buffer-substring-no-properties
                                    (line-beginning-position) (line-end-position))))
                links))))
    (let ((ordered (nreverse links)))
      (list :mtime (file-attribute-modification-time (file-attributes file))
            :title (or title (file-name-sans-extension (file-name-nondirectory file)))
            :tags tags
            :links ordered
            :keys (delete-dups (mapcan (lambda (l) (copy-sequence (nth 1 l))) ordered))
            :scheme-keys (nreverse scheme-keys)))))

(defun pnotes--parse-file (abs-path root)
  "Parse ABS-PATH in ROOT using its live buffer if visited, else disk contents."
  (if-let* ((buf (find-buffer-visiting abs-path)))
      (with-current-buffer buf (pnotes--parse-buffer abs-path root))
    (when (file-exists-p abs-path)
      (with-temp-buffer
        (insert-file-contents abs-path)
        (pnotes--parse-buffer abs-path root)))))

(defun pnotes--cache-update-index (cache rel-path meta add-p)
  "Add (when ADD-P) or remove REL-PATH's inverted index entries using META."
  (dolist (spec `((,(pnotes--cache-backlinks cache) . :keys)
                  (,(pnotes--cache-targets cache) . :projections)))
    (let ((tbl (car spec)))
      (dolist (k (plist-get meta (cdr spec)))
        (if add-p
            (puthash k (cl-adjoin rel-path (gethash k tbl) :test #'string=) tbl)
          (if-let* ((updated (delete rel-path (gethash k tbl))))
              (puthash k updated tbl)
            (remhash k tbl)))))))

(defun pnotes--cache-remove-entry (cache rel-path)
  "Remove REL-PATH and its inverted index entries from CACHE."
  (pnotes--cache-update-index cache rel-path (gethash rel-path (pnotes--cache-files cache)) nil)
  (remhash rel-path (pnotes--cache-files cache)))

(defun pnotes--cache-put-entry (cache rel-path meta)
  "Insert or update REL-PATH with META in CACHE, updating inverted tables."
  (pnotes--cache-remove-entry cache rel-path)
  (let ((full-meta (plist-put (copy-sequence meta) :projections
                              (pnotes--file-projections rel-path meta))))
    (puthash rel-path full-meta (pnotes--cache-files cache))
    (pnotes--cache-update-index cache rel-path full-meta t)))

(defun pnotes--project-note-files (root)
  "Return absolute paths of all managed note files under project ROOT."
  (when-let* ((proj (project-current nil root))
              (exts (pnotes--all-extensions)))
    (cl-remove-if-not (lambda (f)
                        (and (pnotes--has-extension-p f exts)
                             (file-exists-p f)))
                      (project-files proj))))

(defun pnotes--ensure-cache (root)
  "Return the session cache for project ROOT, building it lazily on first access."
  (or (gethash (file-name-as-directory (expand-file-name root)) pnotes--caches)
      (pnotes-cache-reconcile root)))

(defun pnotes-cache-query (root-or-cache fn)
  "Project non-nil (FUNCALL FN REL META CACHE) rows across cached notes."
  (let* ((cache (if (pnotes--cache-p root-or-cache)
                    root-or-cache
                  (pnotes--ensure-cache root-or-cache)))
         rows)
    (maphash (lambda (rel meta)
               (when-let* ((row (funcall fn rel meta cache)))
                 (push row rows)))
             (pnotes--cache-files cache))
    rows))

(defun pnotes--all-tags (root-or-cache)
  "Return sorted deduplicated list of all tags in ROOT-OR-CACHE."
  (sort (delete-dups
         (mapcan #'identity
                 (pnotes-cache-query
                  root-or-cache
                  (lambda (_rel meta _cache) (copy-sequence (plist-get meta :tags))))))
        #'string<))

;;;###autoload
(defun pnotes-cache-reconcile (&optional root)
  "Reconcile session cache for ROOT against file modification times on disk."
  (interactive)
  (let* ((proj-root (file-name-as-directory
                     (expand-file-name (pnotes--require-root root))))
         (cache (or (gethash proj-root pnotes--caches)
                    (puthash proj-root
                             (make-pnotes--cache
                              :files (make-hash-table :test #'equal)
                              :backlinks (make-hash-table :test #'equal)
                              :targets (make-hash-table :test #'equal))
                             pnotes--caches)))
         (seen (make-hash-table :test #'equal))
         (files-tbl (pnotes--cache-files cache)))
    (dolist (abs-file (pnotes--project-note-files proj-root))
      (when-let* ((rel (pnotes--rel-path abs-file proj-root)))
        (puthash rel t seen)
        (let ((disk-mtime (file-attribute-modification-time (file-attributes abs-file))))
          (unless (equal (plist-get (gethash rel files-tbl) :mtime) disk-mtime)
            (pnotes--cache-put-entry cache rel (pnotes--parse-file abs-file proj-root))))))
    (dolist (rel (hash-table-keys files-tbl))
      (unless (gethash rel seen)
        (pnotes--cache-remove-entry cache rel)))
    (when (called-interactively-p 'any)
      (message "Reconciled cache for %s (%d notes)"
               (abbreviate-file-name proj-root)
               (hash-table-count files-tbl)))
    cache))

;;; Follow handler and lifecycle hooks

(defun pnotes--emit (root file event)
  "Notify `pnotes-navigation-hook' subscribers with ROOT, FILE, and EVENT."
  (when (memq event '(follow capture switch))
    (setq pnotes--last-active-file file))
  (run-hook-with-args 'pnotes-navigation-hook root file event))

(defun pnotes--ensure-parent-dir ()
  "Create missing parent directories before saving a newly followed note."
  (when-let* ((file (buffer-file-name))
              (dir (file-name-directory file)))
    (make-directory dir t)))

(defun pnotes--after-save ()
  "Update incremental project cache and notify navigation hooks after saving."
  (when-let* ((file (buffer-file-name))
              (root (pnotes-project-root))
              (rel (pnotes--rel-path file root)))
    (pnotes--cache-put-entry (pnotes--ensure-cache root) rel
                             (pnotes--parse-buffer file root))
    (pnotes--emit root file 'save)))

(defun pnotes--activate-buffer (buf root &optional event)
  "Propagate `pnotes-mode' to BUF when its file lies inside ROOT, returning BUF.
When EVENT is non-nil, emit EVENT via `pnotes--emit'."
  (with-current-buffer buf
    (when-let* ((file (buffer-file-name))
                ((pnotes--rel-path file root)))
      (unless pnotes-mode (pnotes-mode 1))
      (when event (pnotes--emit root file event))))
  buf)

(defun pnotes--open-note (root abs-path &optional event)
  "Visit ABS-PATH inside ROOT, propagating `pnotes-mode'.
When EVENT is non-nil, emit EVENT via `pnotes--emit'.  Return the buffer."
  (pnotes--activate-buffer (find-file abs-path) root event))

(defun pnotes-follow (raw-target)
  "Follow RAW-TARGET using configured link schemes.
Pushes an `xref' return marker, opens existing or unsaved target buffers,
propagates `pnotes-mode', and emits a `follow' navigation event."
  (let ((root (pnotes-project-root)))
    (if-let* ((resolved (pnotes-resolve raw-target default-directory root t)))
        (pcase (plist-get resolved :kind)
          ('follow-fn (funcall (plist-get resolved :fn) (plist-get resolved :path)))
          ('file
           (xref-push-marker-stack)
           (pnotes--open-note root (plist-get resolved :path) 'follow)))
      (user-error "Could not resolve link target: %s" raw-target))))

(defun pnotes-follow-at-point (&optional event)
  "Follow the note link at point, or at mouse EVENT."
  (interactive (list (and (mouse-event-p last-command-event)
                          last-command-event)))
  (when event (mouse-set-point event))
  (if-let* ((target (pnotes--link-at-point)))
      (pnotes-follow target)
    (user-error "No link at point")))

;;; Scheme completion and formatting helpers

(defun pnotes--capf-close-and-maybe-follow (chosen full-target close-str src-dir root existing-p)
  "Insert CLOSE-STR if absent, then follow FULL-TARGET when EXISTING-P is nil."
  (unless (string-suffix-p "/" chosen)
    (when (and close-str (not (looking-at-p (regexp-quote close-str))))
      (insert close-str))
    (unless (or existing-p
                (plist-get (pnotes-resolve full-target src-dir root nil) :exists))
      (pnotes-follow full-target))))

(defun pnotes--capf-table (scheme start end prefix close-str src-dir root row-fn)
  "Return a Capf completion spec for SCHEME projected from ROOT's cache via ROW-FN.
ROW-FN is called as (ROW-FN REL META CACHE) and returns an alist of
(CANDIDATE . ANNOTATION) pairs."
  (let ((src-buf (current-buffer))
        (ann-tbl (make-hash-table :test #'equal))
        (pfx (pnotes--stripped-prefix scheme prefix))
        (create-p (or (plist-get scheme :create-template)
                      (plist-get scheme :template))))
    (dolist (pairs (pnotes-cache-query root row-fn))
      (pcase-dolist (`(,cand . ,ann) pairs)
        (unless (gethash cand ann-tbl)
          (puthash cand ann ann-tbl))))
    (let ((cands (sort (hash-table-keys ann-tbl) #'string<)))
      (list (+ start (length pfx)) end
            (lambda (str pred action)
              (if (eq action 'metadata)
                  '(metadata (category . pnotes-link))
                (complete-with-action
                 action
                 (if (and create-p (not (string-empty-p str)) (not (gethash str ann-tbl)))
                     (append cands (list str))
                   cands)
                 str pred)))
            :exclusive 'no
            :annotation-function (lambda (cand) (or (gethash cand ann-tbl) " [create]"))
            :exit-function
            (lambda (chosen status)
              (when (and (eq (current-buffer) src-buf)
                         (memq status '(finished sole)))
                (pnotes--capf-close-and-maybe-follow
                 chosen (concat pfx chosen) close-str src-dir root
                 (gethash chosen ann-tbl))))))))

(defun pnotes-complete-file-relative (scheme start end prefix close-str src-dir root)
  "Capf completer for relative or prefixed file SCHEME."
  (let ((src-buf (current-buffer))
        (pfx (pnotes--stripped-prefix scheme prefix))
        (exts (or (plist-get scheme :extensions) (pnotes--all-extensions))))
    (list (+ start (length pfx)) end #'completion-file-name-table
          :predicate (lambda (f)
                       (and (not (string-prefix-p "." f))
                            (or (string-suffix-p "/" f)
                                (pnotes--has-extension-p f exts))))
          :exclusive 'no
          :exit-function
          (lambda (chosen status)
            (when (and (eq (current-buffer) src-buf)
                       (memq status '(finished sole)))
              (pnotes--capf-close-and-maybe-follow
               chosen (concat pfx chosen) close-str src-dir root nil))))))

(defun pnotes-complete-root (scheme start end prefix close-str src-dir root)
  "Capf completer for cached root-relative project notes."
  (let ((ext (pnotes--default-extension)))
    (pnotes--capf-table
     scheme start end prefix close-str src-dir root
     (lambda (rel _meta _cache)
       (list (cons (pnotes--strip-ext rel ext) " [note]"))))))

(defun pnotes-complete-symbolic (scheme start end prefix close-str src-dir root)
  "Capf completer for symbolic SCHEME projected values in ROOT."
  (pnotes--capf-table
   scheme start end prefix close-str src-dir root
   (lambda (rel meta _cache)
     (let ((title (plist-get meta :title)))
       (mapcar (lambda (val)
                 (cons val (format " [%s]" (if (string= title val) rel title))))
               (pnotes--scheme-file-values scheme rel meta))))))

(defun pnotes-format-root (scheme rel-path _meta _root &optional _target-dir)
  "Format REL-PATH as a root-relative target for SCHEME."
  (pnotes--strip-ext rel-path (or (car (plist-get scheme :extensions))
                                  (pnotes--default-extension))))

(defun pnotes-format-prefixed-relative (scheme rel-path _meta root &optional target-dir)
  "Format REL-PATH with SCHEME's prefix relative to TARGET-DIR (or ROOT)."
  (let ((pfx (or (car (ensure-list (plist-get scheme :prefix))) ""))
        (rel (if target-dir
                 (file-relative-name (expand-file-name rel-path root) target-dir)
               rel-path)))
    (concat pfx rel)))

(defun pnotes-format-symbolic (scheme rel-path meta _root &optional _target-dir)
  "Format REL-PATH using the first projected value for symbolic SCHEME."
  (when-let* ((val (car (pnotes--scheme-file-values scheme rel-path meta))))
    (concat (pnotes--stripped-prefix scheme) val)))

;;; Capf: link and tag completion

(defun pnotes-capf ()
  "Completion-at-point backend delegating to the buffer adapter and matched scheme."
  (when-let* ((root (pnotes-project-root))
              (adapter (pnotes--buffer-adapter))
              (bounds
               (cl-some
                (lambda (spec)
                  (pcase-let ((`(,re ,close ,reject-bang) spec))
                    (when (and (looking-back re (line-beginning-position))
                               (not (and reject-bang
                                         (eq (char-before (match-beginning 0)) ?!))))
                      (list (match-beginning 1) (point)
                            (match-string-no-properties 1) close))))
                (plist-get adapter :capf-bounds-specs))))
    (pcase-let* ((`(,start ,end ,prefix ,close-str) bounds)
                 (scheme (or (car (pnotes--match-scheme prefix))
                             (unless (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*:" prefix)
                               (or (cl-find-if (lambda (s) (pnotes--bare-scheme-p s t))
                                               pnotes-link-schemes)
                                   (cl-find-if (lambda (s) (plist-get s :complete-fn))
                                               pnotes-link-schemes))))))
      (when-let* ((scheme)
                  (complete-fn (or (plist-get scheme :complete-fn)
                                   (and (plist-get scheme :symbolic) #'pnotes-complete-symbolic)
                                   (and (stringp (plist-get scheme :template)) #'pnotes-complete-root))))
        (funcall complete-fn scheme start end prefix close-str default-directory root)))))

(defun pnotes-tag-capf ()
  "Completion-at-point backend for project tags via the buffer's adapter."
  (when-let* ((root (pnotes-project-root))
              (adapter (pnotes--buffer-adapter))
              (tag-fn (plist-get adapter :tag-capf-fn))
              (start (funcall tag-fn))
              (tags (pnotes--all-tags root)))
    (list start (point) tags
          :exclusive 'no
          :annotation-function (lambda (_) " [tag]"))))

;;; Xref backend (M-. definitions, M-? backlinks)

(cl-defstruct (pnotes-xref-location
               (:include xref-file-location)
               (:constructor pnotes-make-xref-location (file line column root)))
  root)

(cl-defmethod xref-location-marker ((l pnotes-xref-location))
  (let ((marker (cl-call-next-method)))
    (pnotes--activate-buffer (marker-buffer marker) (pnotes-xref-location-root l))
    marker))

(defun pnotes-xref-backend ()
  "Xref backend symbol for `pnotes-mode'."
  (when (pnotes-project-root) 'pnotes-xref))

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql pnotes-xref)))
  (or (pnotes--link-at-point)
      (when-let* ((file (buffer-file-name))
                  (root (pnotes-project-root)))
        (pnotes--rel-path file root))))

(cl-defmethod xref-backend-definitions ((_backend (eql pnotes-xref)) identifier)
  (when-let* ((root (pnotes-project-root))
              (resolved (pnotes-resolve identifier default-directory root t)))
    (pcase (plist-get resolved :kind)
      ('follow-fn (funcall (plist-get resolved :fn) (plist-get resolved :path)) nil)
      ('file
       (list (xref-make identifier
                        (pnotes-make-xref-location
                         (plist-get resolved :path) 1 0 root)))))))

(defun pnotes--backlink-sources (cache target-keys &optional exclude-rel)
  "Return sorted project-relative source paths in CACHE matching TARGET-KEYS.
When EXCLUDE-REL is non-nil, omit EXCLUDE-REL from the result."
  (let ((bl-tbl (pnotes--cache-backlinks cache)))
    (sort (delete exclude-rel
                  (delete-dups
                   (mapcan (lambda (k) (copy-sequence (gethash k bl-tbl)))
                           target-keys)))
          #'string<)))

(defun pnotes--backlinks-for-file (root target &optional source-dir)
  "Return `xref-item' list of backlinks to TARGET within project ROOT."
  (let* ((cache (pnotes--ensure-cache root))
         (files-tbl (pnotes--cache-files cache))
         (tkeys (if-let* ((entry (gethash target files-tbl)))
                    (plist-get entry :projections)
                  (when-let* ((clean (pnotes--clean-target target)))
                    (pnotes--link-keys clean (or source-dir root) root)))))
    (mapcan
     (lambda (src-rel)
       (let ((abs-src (expand-file-name src-rel root)))
         (delq nil
               (mapcar (lambda (link)
                         (pcase-let ((`(,_tgt ,lkeys ,line ,col ,summary) link))
                           (when (cl-some (lambda (k) (member k tkeys)) lkeys)
                             (xref-make summary (pnotes-make-xref-location
                                                 abs-src line col root)))))
                       (plist-get (gethash src-rel files-tbl) :links)))))
     (pnotes--backlink-sources cache tkeys target))))

(cl-defmethod xref-backend-references ((_backend (eql pnotes-xref)) identifier)
  "Find all backlinks to IDENTIFIER via the template-driven inverted cache."
  (when-let* ((root (pnotes-project-root)))
    (pnotes--backlinks-for-file
     root
     (or (plist-get (pnotes-resolve identifier default-directory root nil) :rel)
         identifier)
     default-directory)))

;;;###autoload
(defun pnotes-backlinks ()
  "Show backlinks to the current project note in an `xref' buffer."
  (interactive)
  (if-let* ((file (buffer-file-name))
            (root (pnotes-project-root))
            (rel (pnotes--rel-path file root)))
      (let ((default-directory root))
        (xref-show-xrefs (lambda () (pnotes--backlinks-for-file root rel)) nil))
    (user-error "Current buffer is not visiting a managed project note")))

;;;###autoload
(defun pnotes-find ()
  "Find a note in the active project."
  (interactive)
  (let* ((root (pnotes--require-root))
         (files-tbl (pnotes--cache-files (pnotes--ensure-cache root)))
         (cands (or (sort (hash-table-keys files-tbl) #'string<)
                    (user-error "No notes found in %s" (abbreviate-file-name root))))
         (completion-extra-properties
          (list :annotation-function
                (lambda (cand)
                  (let* ((meta (gethash cand files-tbl))
                         (title (plist-get meta :title))
                         (stem (file-name-sans-extension (file-name-nondirectory cand)))
                         (parts (append (unless (string= title stem) (list title))
                                        (mapcar (lambda (tg) (concat "#" tg))
                                                (plist-get meta :tags)))))
                    (when parts
                      (propertize (concat "  " (string-join parts "  "))
                                  'face 'completions-annotations))))))
         (choice (completing-read "Note: " cands nil t)))
    (pnotes--open-note root (expand-file-name choice root) 'follow)))

;;; Daily notes

;;;###autoload
(defun pnotes-daily (&optional day-offset)
  "Open today's daily note (or offset by DAY-OFFSET days)."
  (interactive (list (if current-prefix-arg (prefix-numeric-value current-prefix-arg) 0)))
  (let* ((root (pnotes--require-root))
         (target-time (time-add (current-time) (days-to-time (or day-offset 0))))
         (path (expand-file-name
                (concat (format-time-string pnotes-daily-format target-time)
                        "." (pnotes--default-extension))
                (expand-file-name pnotes-daily-directory root)))
         (existed (file-exists-p path))
         (buf (pnotes--open-note root path 'follow)))
    (with-current-buffer buf
      (when-let* (((not existed))
                  ((zerop (buffer-size)))
                  (fn pnotes-daily-header-function)
                  (header (funcall fn target-time path)))
        (insert header)))
    buf))

;;; Project search and tag search

(defun pnotes--grep (root regexp &optional initial-consult-regexp)
  "Search managed notes under ROOT via `consult-ripgrep' or `xref'.
REGEXP is passed to `xref-matches-in-files' when `consult-ripgrep' is
unavailable.  INITIAL-CONSULT-REGEXP (falling back to REGEXP) supplies the
initial input to `consult-ripgrep'."
  (if (fboundp 'consult-ripgrep)
      (progn
        (require 'consult nil t)
        (let* ((globs (mapcar (lambda (ext) (format "--glob=*.%s" ext))
                              (pnotes--all-extensions)))
               (consult-ripgrep-args
                (if (listp consult-ripgrep-args)
                    (append consult-ripgrep-args globs)
                  (string-join (cons consult-ripgrep-args globs) " "))))
          (consult-ripgrep root (or initial-consult-regexp regexp))
          (pnotes--activate-buffer (window-buffer (selected-window)) root 'follow)))
    (let ((default-directory root)
          (re (or regexp (read-regexp "Search notes: " initial-consult-regexp))))
      (xref-show-xrefs
       (lambda ()
         (if-let* ((files (pnotes--project-note-files root))
                   (xrefs (xref-matches-in-files re files)))
             (dolist (item xrefs xrefs)
               (let ((loc (xref-item-location item)))
                 (when (xref-file-location-p loc)
                   (setf (xref-item-location item)
                         (pnotes-make-xref-location
                          (xref-file-location-file loc)
                          (xref-file-location-line loc)
                          (xref-file-location-column loc)
                          root)))))
           (user-error "No matches for: %s" re)))
       nil))))

;;;###autoload
(defun pnotes-search (&optional initial)
  "Search across all notes in the active project.
When INITIAL is non-nil, prefill the search input with it."
  (interactive)
  (pnotes--grep (pnotes--require-root) nil initial))

;;;###autoload
(defun pnotes-search-tag (&optional tag root-override)
  "Search project notes matching TAG using active format adapters.
When TAG is nil, prompt with completion over cached project tags.
ROOT-OVERRIDE, when non-nil, overrides `(pnotes-project-root)'."
  (interactive)
  (let* ((root (pnotes--require-root root-override))
         (raw (or tag (completing-read "Tag: " (pnotes--all-tags root) nil nil)))
         (clean (string-trim (or raw "") "[ \t\n\r#:]+" "[ \t\n\r:]+"))
         emacs-parts)
    (when (string-empty-p clean)
      (user-error "Tag cannot be empty"))
    (dolist (adapter (delete-dups
                      (mapcar #'pnotes--adapter-for-extension
                              (or (pnotes--all-extensions) '(nil)))))
      (when-let* ((fn (plist-get adapter :tag-search-regexp-fn))
                  (part (funcall fn clean))
                  ((not (string-empty-p part))))
        (cl-pushnew part emacs-parts :test #'string=)))
    (let* ((raw-re (if emacs-parts
                       (format "\\(%s\\)" (string-join (nreverse emacs-parts) "\\|"))
                     (regexp-quote clean)))
           (emacs-re (replace-regexp-in-string " " "[[:blank:]]" raw-re t t)))
      (pcase-let ((`(,consult-async-split-style . ,initial)
                   (cond
                    ((not (string-search ";" emacs-re)) (cons 'semicolon (concat emacs-re ";")))
                    ((not (string-search "," emacs-re)) (cons 'comma (concat emacs-re ",")))
                    (t (cons 'none emacs-re)))))
        (pnotes--grep root emacs-re initial)))))

;;; Project-scoped capture via remember.el

(defun pnotes--remember-handler ()
  "Store capture buffer in the active project inbox."
  (let* ((root (pnotes--require-root))
         (inbox (expand-file-name pnotes-inbox-directory root))
         (base (format-time-string pnotes-capture-file-format))
         (ext (pnotes--default-extension))
         (abs-path (expand-file-name (concat base "." ext) inbox))
         (n 1))
    (while (file-exists-p abs-path)
      (setq abs-path (expand-file-name (format "%s-%d.%s" base n ext) inbox)
            n (1+ n)))
    (make-directory inbox t)
    (write-region (point-min) (point-max) abs-path nil 'silent)
    (when-let* ((rel (pnotes--rel-path abs-path root)))
      (pnotes--cache-put-entry (pnotes--ensure-cache root) rel
                               (pnotes--parse-file abs-path root)))
    (run-at-time 0 nil
                 (lambda (r f open-p)
                   (if open-p
                       (pnotes--open-note r f 'capture)
                     (pnotes--emit r f 'capture)))
                 root abs-path pnotes-capture-open-after-save)
    t))

;;;###autoload
(defun pnotes-capture ()
  "Capture a note into the active project's inbox using `remember.el'."
  (interactive)
  (let* ((root (pnotes--require-root))
         (inbox (file-name-as-directory (expand-file-name pnotes-inbox-directory root)))
         (capture-adapter (pnotes--adapter-for-extension (pnotes--default-extension)))
         (wrap-fn (or (plist-get capture-adapter :format-link-fn)
                      #'pnotes-adapter-wiki-format-link))
         (annotation
          (when-let* ((pnotes-capture-annotate)
                      (src-file (buffer-file-name))
                      (src-rel (pnotes--rel-path src-file root)))
            (let ((meta (gethash src-rel (pnotes--cache-files (pnotes--ensure-cache root)))))
              (funcall wrap-fn
                       (or (cl-some (lambda (s)
                                      (when-let* ((fn (plist-get s :format-fn)))
                                        (funcall fn s src-rel meta root inbox)))
                                    pnotes-link-schemes)
                           (pnotes--strip-ext src-rel (pnotes--default-extension)))))))
         (remember-annotation-functions (when annotation (list (lambda () annotation)))))
    (remember)
    (with-current-buffer remember-buffer
      (setq-local default-directory root
                  remember-handler-functions (list #'pnotes--remember-handler))
      (pnotes-mode 1))))

;;; Font-lock link activation and passive hooks

(defvar-keymap pnotes-link-map
  :doc "Text-property keymap applied to navigable `pnotes' links."
  "RET" #'pnotes-follow-at-point
  "C-c C-o" #'pnotes-follow-at-point
  "<mouse-1>" #'pnotes-follow-at-point
  "<mouse-2>" #'pnotes-follow-at-point)

(defconst pnotes--font-lock-props
  '(keymap mouse-face follow-link help-echo pnotes-link-target)
  "Text properties managed on links by `pnotes--fontify-links'.")

(defun pnotes--fontify-links (limit)
  "Font-lock matcher applying `pnotes-link-map' and face to links up to LIMIT."
  (when-let* ((adapter (pnotes--buffer-adapter)))
    (dolist (item (pnotes--adapter-scan-region adapter (point) limit))
      (pcase-let* ((`(,target ,beg . ,end) item))
        (when (pnotes--note-target-p target)
          (add-text-properties
           beg end
           (list 'face 'pnotes-link
                 'mouse-face 'highlight
                 'follow-link t
                 'keymap pnotes-link-map
                 'help-echo (format "pnotes: %s" target)
                 'pnotes-link-target target))))))
  nil)

(defun pnotes--set-font-lock (enable)
  "Enable or disable `pnotes' link fontification in the current buffer."
  (font-lock-remove-keywords nil '((pnotes--fontify-links)))
  (when enable
    (make-local-variable 'font-lock-extra-managed-props)
    (dolist (prop pnotes--font-lock-props)
      (cl-pushnew prop font-lock-extra-managed-props))
    (font-lock-add-keywords nil '((pnotes--fontify-links)) 'append))
  (font-lock-flush))

(defun pnotes--on-xref-jump ()
  "Emit `follow' after an `xref' jump into a `pnotes-mode' buffer."
  (when-let* ((file (buffer-file-name))
              (root (pnotes-project-root)))
    (pnotes--emit root file 'follow)))

(defun pnotes--on-window-change (window)
  "Emit `switch' when WINDOW becomes selected on a different note buffer."
  (when-let* (((eq window (selected-window)))
              (file (buffer-file-name))
              ((not (equal file pnotes--last-active-file)))
              (root (pnotes-project-root)))
    (pnotes--emit root file 'switch)))

;;; Keymaps and minor mode

(defconst pnotes--core-hooks
  '((completion-at-point-functions . pnotes-capf)
    (completion-at-point-functions . pnotes-tag-capf)
    (xref-backend-functions . pnotes-xref-backend)
    (xref-after-jump-hook . pnotes--on-xref-jump)
    (window-selection-change-functions . pnotes--on-window-change)
    (window-buffer-change-functions . pnotes--on-window-change)
    (before-save-hook . pnotes--ensure-parent-dir)
    (after-save-hook . pnotes--after-save))
  "Core buffer-local hooks managed by `pnotes-mode'.")

(defun pnotes--file-binding-filter (cmd)
  "Return CMD only when the current buffer visits a file."
  (when (buffer-file-name) cmd))

(defvar-keymap pnotes-command-map
  :doc "Prefix keymap for `pnotes' commands."
  "/" #'pnotes-search
  "b" '(menu-item "Backlinks" pnotes-backlinks :filter pnotes--file-binding-filter)
  "c" #'pnotes-capture
  "d" #'pnotes-daily
  "f" #'pnotes-find
  "g" #'pnotes-graph
  "i" #'pnotes-inbox-review
  "o" '(menu-item "Overview" pnotes-speedbar-overview :filter pnotes--file-binding-filter)
  "r" #'pnotes-cache-reconcile
  "s" #'pnotes-speedbar-toggle
  "t" #'pnotes-search-tag
  "w" #'pnotes)

(defvar-keymap pnotes-mode-map
  :doc "Keymap for `pnotes-mode'.")

(defcustom pnotes-keymap-prefix "C-c n"
  "Prefix key sequence for `pnotes-command-map' inside `pnotes-mode-map'."
  :type 'string
  :set (lambda (sym val)
         (when (and (boundp sym) (stringp (symbol-value sym)))
           (keymap-unset pnotes-mode-map (symbol-value sym) t))
         (set-default sym val)
         (when (stringp val)
           (keymap-set pnotes-mode-map val pnotes-command-map)))
  :group 'pnotes)

;;;###autoload
(define-minor-mode pnotes-mode
  "Project-bound note navigation, template link resolution, and remember capture."
  :init-value nil
  :lighter " PNotes"
  :keymap pnotes-mode-map
  (if pnotes-mode
      (if (pnotes-project-root)
          (progn
            (dolist (pair pnotes--core-hooks)
              (add-hook (car pair) (cdr pair) nil t))
            (pnotes--set-font-lock t))
        (setq pnotes-mode nil)
        (when (called-interactively-p 'any)
          (user-error "Cannot enable pnotes-mode outside a recognised project")))
    (dolist (pair pnotes--core-hooks)
      (remove-hook (car pair) (cdr pair) t))
    (pnotes--set-font-lock nil)))

;;; Built-in mode and format adapter helpers

(defconst pnotes-adapter--trim-chars "[ \t\n\r\"']+"
  "Characters trimmed from parsed metadata titles and YAML list items.")

(defun pnotes-adapter-wiki-format-link (target &optional _title)
  "Format TARGET as a bracket link `[[TARGET]]'."
  (format "[[%s]]" target))

(defun pnotes-adapter--extract-line (regexp)
  "Search from `point-min' for REGEXP and return trimmed group 1, or nil."
  (goto-char (point-min))
  (when (re-search-forward regexp nil t)
    (let ((val (string-trim (match-string-no-properties 1)
                            pnotes-adapter--trim-chars
                            pnotes-adapter--trim-chars)))
      (unless (string-empty-p val) val))))

(defun pnotes-adapter-org-parse-meta ()
  "Parse Org `#+title:' and `#+filetags:' from the current buffer."
  (let ((case-fold-search t))
    (list :title (pnotes-adapter--extract-line "^#\\+title:[ \t]+\\(.+\\)$")
          :tags (when-let* ((raw (pnotes-adapter--extract-line
                                  "^#\\+filetags:[ \t]*\\(.+\\)$")))
                  (split-string raw "[: \t]+" t)))))

(defun pnotes-adapter-org-tag-capf ()
  "Return start position for Org `#+filetags:' tag completion, or nil."
  (let ((case-fold-search t))
    (when (looking-back "^#\\+filetags:[ \t]+\\(?:.*[: \t]\\)?\\([[:alnum:]_/-]*\\)"
                        (line-beginning-position))
      (match-beginning 1))))

(defun pnotes-adapter-org-tag-search-regexp (clean)
  "Return a space-free Emacs regexp matching Org tag CLEAN."
  (format ":%s:" (regexp-quote clean)))

(defun pnotes-adapter-markdown-link-match ()
  "Extract wiki or non-image Markdown link target from the current match."
  (or (match-string-no-properties 1)
      (unless (eq (char-before (match-beginning 0)) ?!)
        (match-string-no-properties 2))))

(defun pnotes-adapter-markdown-parse-meta ()
  "Parse YAML title/tags, Markdown H1 title, and inline hashtags from buffer."
  (let* ((case-fold-search t)
         (title (pnotes-adapter--extract-line "^\\(?:title:\\|#\\)[ \t]+\\(.+\\)$"))
         tags)
    (goto-char (point-min))
    (when (re-search-forward "^tags:[ \t]*\\(.*\\)$" nil t)
      (let ((inline (string-trim (match-string-no-properties 1))))
        (if (not (string-empty-p inline))
            (setq tags (split-string inline "[:,][ \t]*" t "[][\"' \t]+"))
          (while (and (= (forward-line 1) 0)
                      (looking-at "^[ \t]+-[ \t]+\\(.+\\)$"))
            (dolist (item (split-string (match-string-no-properties 1)
                                        "$^" t pnotes-adapter--trim-chars))
              (cl-pushnew item tags :test #'string=))))))
    (goto-char (point-min))
    (while (re-search-forward "\\(?:^\\|[ \t]\\)#\\([[:alnum:]_][[:alnum:]_/-]*\\)\\b" nil t)
      (let ((tag (match-string-no-properties 1)))
        (unless (string-match-p
                 "\\`\\(?:[0-9]+\\|[0-9a-f]\\{6\\}\\|[0-9a-f]\\{8\\}\\|[0-9][0-9a-f]\\{2,3\\}\\)\\'"
                 tag)
          (cl-pushnew tag tags :test #'string=))))
    (list :title title :tags (nreverse tags))))

(defun pnotes-adapter-markdown-tag-capf ()
  "Return start position for YAML or inline hashtag completion, or nil."
  (let ((bol (line-beginning-position))
        (case-fold-search t))
    (when (or (looking-back "^tags:[ \t]+\\(?:.*[,\\[ \t\"']\\)?\\([[:alnum:]_/-]*\\)" bol)
              (and (looking-back "^[ \t]+-[ \t]+[\"']?\\([[:alnum:]_/-]*\\)" bol)
                   (save-excursion
                     (while (and (= (forward-line -1) 0) (looking-at-p "^[ \t]+-[ \t]+")))
                     (looking-at-p "^tags:[ \t]*$")))
              (and (looking-back "\\(?:^\\|[ \t]\\)#\\([[:alnum:]_/-]*\\)" bol)
                   (not (save-excursion (goto-char (match-beginning 0))
                                        (looking-at-p "^#+[ \t]")))))
      (match-beginning 1))))

(defun pnotes-adapter-markdown-tag-search-regexp (clean)
  "Return a space-free Emacs regexp matching YAML and inline Markdown tag CLEAN."
  (let ((quoted (regexp-quote clean)))
    (format "\\(?:^\\|[[:blank:]]\\)#%s\\b\\|tags:.*\\b%s\\b\\|^[[:blank:]]+-[[:blank:]]+[\"']?%s[\"']?[[:blank:]]*$"
            quoted quoted quoted)))

(provide 'pnotes)
;;; pnotes.el ends here
