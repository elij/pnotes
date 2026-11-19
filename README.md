# pnotes

`pnotes` is a project-scoped note engine for Emacs 31+ that uses as much built in functionality as possible. With optional dependencies on [consult.el](https://github.com/minad/consult), [Ripgrep](https://github.com/BurntSushi/ripgrep) and [graph-fa2](https://github.com/elij/graph-fa2).

`pnotes` started life as an extension to the excellent [Grove](https://github.com/jonathanchu/grove) and keeps the spirit of keeping the noting solution as minimal as possible.

<img width="1175" height="926" alt="PNotes" src="https://github.com/user-attachments/assets/197535aa-8cc3-4cfd-b6a8-818b6c28761b" />

It comes with no noting scheme and instead resolves links through a scheme registry (`pnotes-link-schemes`), adapts to major modes and document through format adapters (`pnotes-mode-adapters`), and keeps a per-project cache for completion, `xref` backlinks, `remember.el` capture, and UI views (`pnotes-ui.el`, `pnotes-speedbar.el`, `pnotes-graph.el`).

## Activation and keybindings

`pnotes-mode` is buffer-local and project-bound via `project.el`. Once enabled in an entry buffer (or chained from another minor mode), navigating via `pnotes` commands propagates `pnotes-mode` to visited notes inside the same project.

| Key | Command | Action |
|---|---|---|
| `C-c n /` | `pnotes-search` | Full-text search (`consult-ripgrep` or `xref`) |
| `C-c n b` | `pnotes-backlinks` | Show backlinks in `xref` |
| `C-c n c` | `pnotes-capture` | Capture into project inbox via `remember.el` |
| `C-c n d` | `pnotes-daily` | Open or create daily note |
| `C-c n f` | `pnotes-find` | Find cached project note |
| `C-c n g` | `pnotes-graph` | Force-directed graph (`graph-fa2`) |
| `C-c n i` | `pnotes-inbox-review` | Triage inbox, untagged, and unlinked notes |
| `C-c n o` | `pnotes-speedbar-overview` | Speedbar outline, tags, links, and backlinks |
| `C-c n r` | `pnotes-cache-reconcile` | Reconcile session cache with disk mtimes |
| `C-c n s` | `pnotes-speedbar-toggle` | Toggle Speedbar file tree |
| `C-c n t` | `pnotes-search-tag` | Search notes by tag |
| `C-c n w` | `pnotes` | Open project welcome page |

## Installation

```elisp
(package-vc-install 
   '(pnotes . (:url "https://github.com/elij/pnotes")))
```

## Example link schemes

`pnotes-link-schemes` ships with a mixed Markdown and Org default (the Grove model). To tailor `pnotes` to a specific note convention, set `pnotes-link-schemes` globally or via `.dir-locals.el`.

### Obsidian

Supports `[[note]]`, `[[note|alias]]`, `[[note#heading]]`, Markdown inline links `[label](path)`, relative `./` and `../` paths, root-relative paths, shortest-path filename matching across subfolders (`stem`), and YAML/heading `title` lookup:

```elisp
(setq pnotes-link-schemes
      '((:name relative
               :prefix ("./" "../")
               :template "%d/%p.%e"
               :complete-fn pnotes-complete-file-relative
               :extensions ("md")
               :index t)
        (:name root
               :prefix nil
               :template "%r/%p.%e"
               :complete-fn pnotes-complete-root
               :format-fn pnotes-format-root
               :extensions ("md")
               :index t)
        (:name stem
               :symbolic t
               :project-source filename
               :project-fn file-name-sans-extension
               :normalize-fn file-name-sans-extension
               :complete-fn pnotes-complete-symbolic
               :extensions ("md")
               :index t)
        (:name title
               :symbolic t
               :project-source meta
               :project-fn (lambda (meta) (plist-get meta :title))
               :extensions ("md")
               :index t)))
```

### Denote

Supports `denote:YYYYMMDDTHHMMSS` links extracted from filenames, automatic creation of unresolved Denote notes, and relative/root fallbacks across `.org`, `.md`, and `.txt` files:

```elisp
(setq pnotes-link-schemes
      '((:name denote
               :prefix "denote:"
               :strip-prefix t
               :symbolic t
               :project-source filename
               :project-regexp "\\`\\([0-9]\\{8\\}T[0-9]\\{6\\}\\)"
               :create-template "%r/%p--untitled.%e"
               :complete-fn pnotes-complete-symbolic
               :format-fn pnotes-format-symbolic
               :extensions ("org" "md" "txt")
               :index t)
        (:name relative
               :prefix ("./" "../")
               :template "%d/%p.%e"
               :complete-fn pnotes-complete-file-relative
               :extensions ("org" "md" "txt")
               :index t)
        (:name root
               :prefix nil
               :template "%r/%p.%e"
               :complete-fn pnotes-complete-root
               :format-fn pnotes-format-root
               :extensions ("org" "md" "txt")
               :index t)))
```

### Vulpea, Org-roam, and Org-ID

Indexes `:ID:` properties from Org buffers with fallback to `org-id-open`, relative `file:` links, and bare `#+title:` lookup:

```elisp
(setq pnotes-link-schemes
      '((:name org-id
               :prefix "id:"
               :strip-prefix t
               :symbolic t
               :project-source buffer
               :project-regexp "^[ \t]*:ID:[ \t]+\\([^ \t\n]+\\)"
               :follow-fn org-id-open
               :complete-fn pnotes-complete-symbolic
               :format-fn pnotes-format-symbolic
               :extensions ("org")
               :index t)
        (:name org-file
               :prefix "file:"
               :strip-prefix t
               :template "%d/%p.%e"
               :complete-fn pnotes-complete-file-relative
               :format-fn pnotes-format-prefixed-relative
               :extensions ("org")
               :index t)
        (:name title
               :symbolic t
               :project-source meta
               :project-fn (lambda (meta) (plist-get meta :title))
               :complete-fn pnotes-complete-symbolic
               :extensions ("org")
               :index t)))
```

### File-based Org

```elisp
(setq pnotes-link-schemes
      '((:name org-file
               :prefix "file:"
               :strip-prefix t
               :template "%d/%p.%e"
               :complete-fn pnotes-complete-file-relative
               :extensions ("org")
               :index t)
        (:name relative
               :prefix ("./" "../")
               :template "%d/%p.%e"
               :complete-fn pnotes-complete-file-relative
               :extensions ("org")
               :index t)
        (:name root
               :prefix nil
               :template "%r/%p.%e"
               :complete-fn pnotes-complete-root
               :format-fn pnotes-format-root
               :extensions ("org")
               :index t)))
```

## Writing a custom scheme

Each entry in `pnotes-link-schemes` is a plist evaluated in order:

- Matching: `:regexp` matches the cleaned target, `:prefix` matches one string or a list of strings (with `:strip-prefix t` to strip the prefix before resolution), and a non-symbolic entry with neither `:regexp` nor `:prefix` acts as the bare fallback scheme.
- Action-only schemes: omit `:template` and supply `:follow-fn` (function symbol or lambda) plus `:index nil`.
- Path schemes: supply `:template` using `%r` (project root), `%d` (current file directory), `%p` (target path), and `%e` (extension).
- Symbolic schemes: set `:symbolic t`, `:project-source` (`filename`, `buffer`, or `meta`), and either `:project-regexp` (capture group 1) or `:project-fn`. Add `:normalize-fn` if incoming link targets need transformation before lookup, `:create-template` to create missing targets, and `:follow-fn` as a fallback on cache misses.
- Completion and formatting: wire `:complete-fn` to one of the built-in helpers (`pnotes-complete-file-relative`, `pnotes-complete-root`, `pnotes-complete-symbolic`) or a custom function `(SCHEME START END PREFIX CLOSE SRC-DIR ROOT)`, and `:format-fn` to `pnotes-format-root`, `pnotes-format-prefixed-relative`, `pnotes-format-symbolic`, or a custom formatter `(SCHEME REL-PATH META ROOT TARGET-DIR)`.

Example custom scheme for issue tracker links (`[[ticket:ENG-42]]`):

```elisp
(add-to-list 'pnotes-link-schemes
             `(:name ticket
                     :prefix "ticket:"
                     :strip-prefix t
                     :follow-fn ,(lambda (id)
                                   (browse-url (format "https://tracker.example.com/browse/%s" id)))
                     :index nil))
```

## Writing a custom mode adapter

`pnotes-mode-adapters` maps major modes (`:modes`) and disk file extensions (`:extensions`) to syntax rules. Most adapters only need declarative keys:

```elisp
(add-to-list 'pnotes-mode-adapters
             '(:name rst
                     :modes (rst-mode)
                     :extensions ("rst")
                     :link-regexp ":doc:`\\([^`\n]+\\)`"
                     :capf-bounds-specs ((":doc:`\\([^`\n]*\\)" "`"))
                     :format-link-fn (lambda (target &optional _title)
                                       (format ":doc:`%s`" target))
                     :daily-header-template "%H\n==========\n\n:date: %I\n\n"))
```

Adapters can also supply function hooks for format-specific logic (`:link-match-fn`, `:format-link-fn`, `:parse-meta-fn`, `:tag-capf-fn`, and `:tag-search-regexp-fn`).
