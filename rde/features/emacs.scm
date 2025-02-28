(define-module (rde features emacs)
  #:use-module (rde features)
  #:use-module (rde features predicates)
  #:use-module (gnu home-services)
  #:use-module (gnu home-services emacs)
  #:use-module (gnu home-services wm)
  #:use-module (gnu home-services xdg)
  #:use-module (gnu home-services-utils)
  #:use-module (gnu services)

  #:use-module (rde packages)
  #:use-module (gnu packages emacs-xyz)
  #:use-module (gnu packages mail)

  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix transformations)

  #:export (feature-emacs
            feature-emacs-appearance
            feature-emacs-faces
	    feature-emacs-completion
	    feature-emacs-input-methods
	    feature-emacs-project
	    feature-emacs-perspective
	    feature-emacs-git
	    feature-emacs-dired
            feature-emacs-eshell
	    feature-emacs-monocle
	    feature-emacs-org
	    feature-emacs-org-roam
	    feature-emacs-erc
            feature-emacs-elpher
	    feature-emacs-telega
	    feature-emacs-pdf-tools
            feature-emacs-which-key
            feature-emacs-keycast

            elisp-configuration-service
            emacs-xdg-service))

(define* (elisp-configuration-service
          name
          #:optional (elisp-expressions '())
          #:key
          (early-init '())
          (elisp-packages '())
          (autoloads? #t))
  (let* ((configure-package
	  (elisp-configuration-package
	   (string-append "configure-" (symbol->string name))
           elisp-expressions
           #:elisp-packages elisp-packages
           #:autoloads? autoloads?)))
    (simple-service
     (symbol-append 'emacs- name '-configurations)
     home-emacs-service-type
     (home-emacs-extension
      (early-init-el early-init)
      ;; It's necessary to explicitly add elisp-packages here, because
      ;; we want to overwrite builtin emacs packages.  Propagated
      ;; inputs have lowest priority on collisions, that's why we have
      ;; to list those package here in addition to propagated-inputs.
      (elisp-packages (append elisp-packages (list configure-package)))))))

;; MAYBE: make handler to be actions instead of desktop entries?
(define* (emacs-xdg-service
          name xdg-name gexp
          #:key
          (default-for '())
          (exec-argument "%u"))
  (define file-name (string-append "emacs-" (symbol->string name)))
  (define file-file (file-append (program-file file-name gexp)
                                 (string-append " " exec-argument)))
  (define desktop-file (symbol-append 'emacs- name '.desktop))
  (simple-service
   (symbol-append 'emacs-xdg- name)
   home-xdg-mime-applications-service-type
   (home-xdg-mime-applications-configuration
    (default (map (lambda (m) (cons m desktop-file)) default-for))
    (desktop-entries
     (list
      (xdg-desktop-entry
       (file file-name)
       (name xdg-name)
       (config `((exec . ,file-file)))
       (type 'application)))))))



(define* (feature-emacs
	  #:key
	  (package emacs-next-pgtk-latest)
	  (emacs-server-mode? #t)
	  (additional-elisp-packages '())
          (extra-config '()))
  "Setup and configure GNU Emacs."
  (ensure-pred boolean? emacs-server-mode?)
  (ensure-pred list-of-elisp-packages? additional-elisp-packages)
  (ensure-pred package? package)

  (define emacs-client (file-append package "/bin/emacsclient"))
  (define emacs-client-create-frame
    (program-file "emacs-client-create-frame"
		  #~(apply system*
			   #$(file-append package "/bin/emacsclient")
			   "--create-frame"
			   (cdr (command-line)))))
  (define emacs-client-no-wait
    (program-file "emacs-client-no-wait"
		  #~(apply system*
			   #$(file-append package "/bin/emacsclient")
			   "--no-wait"
			   (cdr (command-line)))))
  (define emacs-editor
    (program-file "emacs-editor"
		  #~(apply system*
			   #$(file-append package "/bin/emacs")
			   "--no-splash"
			   (cdr (command-line)))))

  (define (emacs-home-services config)
    "Returns home services related to GNU Emacs."
    (require-value 'full-name config)
    (require-value 'email config)
    (let* ((full-name (get-value 'full-name config))
	   (email     (get-value 'email config)))
      (list
       (emacs-xdg-service 'emacs-q "Emacs (No init: -q)"
                          #~(system* "emacs" "-q"))
       (emacs-xdg-service 'emacs-Q "Emacs (No init, no site-lisp: -Q)"
                          #~(system* "emacs" "-Q"))
       (service
	home-emacs-service-type
	(home-emacs-configuration
	 (package package)
	 (elisp-packages (cons* emacs-guix
                                emacs-expand-region
                                additional-elisp-packages))
	 (server-mode? emacs-server-mode?)
	 (xdg-flavor? #t)
	 (init-el
	  `((setq user-full-name ,full-name)
	    (setq user-mail-address ,email)

            ,#~""
	    (setq custom-file
		  (concat (or (getenv "XDG_CACHE_HOME") "~/.cache")
			  "/emacs/custom.el"))
	    (load custom-file t)

            ,#~""
            (define-key global-map (kbd "C-=") 'er/expand-region)

            ,#~""
            (defun rde/display-load-time ()
              (interactive)
              (message "rde emacs loaded in %s, C-h r i for search in emacs manual by topic. C-h C-a for welcome screen." (emacs-init-time)))

            ;; (setq inhibit-splash-screen t)
            (defun display-startup-echo-area-message ()
              (rde/display-load-time))
	    ,#~""

            (defun rde-compilation-colorizer ()
              "Prevent color escape sequences to popup in compilation buffer."
              (ansi-color-apply-on-region compilation-filter-start (point)))
            (add-hook 'compilation-filter-hook 'rde-compilation-colorizer)

            ;; <https://emacsredux.com/blog/2013/05/22/smarter-navigation-to-the-beginning-of-a-line/>
            ;; Actually there is M-m for back-to-indentation
            (defun smarter-move-beginning-of-line (arg)
              "Move point back to indentation of beginning of line.

Move point to the first non-whitespace character on this line.
If point is already there, move to the beginning of the line.
Effectively toggle between the first non-whitespace character and
the beginning of the line.

If ARG is not nil or 1, move forward ARG - 1 lines first.  If
point reaches the beginning or end of the buffer, stop there."
              (interactive "^p")
              (setq arg (or arg 1))

              ;; Move lines first
              (when (/= arg 1)
                (let ((line-move-visual nil))
                  (forward-line (- arg 1))))

              (let ((orig-point (point)))
                (move-beginning-of-line 1)
                (when (= orig-point (point))
                  (back-to-indentation))))
            ,#~"
(define-key global-map
  [remap move-beginning-of-line]
  'smarter-move-beginning-of-line)\n"

	    (column-number-mode 1)
	    (save-place-mode 1)
	    (show-paren-mode 1)
            ;; (add-hook 'prog-mode-hook 'electric-pair-mode)

            ;; TODO: Move to feature-emacs-guix.
            (global-guix-prettify-mode)

	    (setq-default indent-tabs-mode nil)
	    (setq save-interprogram-paste-before-kill t)
	    (setq mouse-yank-at-point t)
	    (setq require-final-newline t)
            (add-hook 'prog-mode-hook
                      (lambda () (setq show-trailing-whitespace t)))

            (setq backup-directory-alist
                  `(,(cons "." (concat (or (getenv "XDG_CACHE_HOME") "~/.cache")
		                       "/emacs/backup"))))

            ;; MAYBE: Move to dired
            (dolist (mode-hook '(prog-mode-hook dired-mode-hook
                                 compilation-mode-hook))
                    (add-hook mode-hook (lambda () (setq truncate-lines t))))
	    (define-key global-map (kbd "s-r") 'recompile)

            ,@extra-config))
	 (early-init-el
	  `(,(slurp-file-gexp (local-file "./emacs/early-init.el"))))
	 ;;; TODO: Rebuilding packages with emacs will be useful for
	 ;;; native-comp, but for some reason dash.el fails to build,
	 ;;; need to investigate the issue.
	 ;; (rebuild-elisp-packages? #t)
	 ))

       (simple-service 'emacs-set-default-editor
		       home-environment-variables-service-type
		       `(("ALTERNATE_EDITOR" . ,emacs-editor)
			 ("VISUAL" . ,emacs-client-no-wait)))
       (when (get-value 'sway config)
 	 (simple-service
	  'emacs-update-environment-variables-on-sway-start
	  home-sway-service-type
	  `((exec_always "sleep 2s && " ;; Need to wait until emacs daemon loaded.
	     ,(program-file
	       "update-emacs-env-variables"
	       #~(system*
		  #$emacs-client "--eval"
		  (string-append
                   "(mapcar (lambda (lst) (apply #'setenv lst)) '"
                   (let* ((port   ((@@ (ice-9 popen) open-input-pipe)
		                   (string-append "env")))
	                  (result ((@@ (ice-9 rdelim) read-delimited) "" port))
	                  (vars (map (lambda (x)
                                       (let ((si (string-index x #\=)))
                                         (list (string-take x si)
                                               (string-drop x (+ 1 si)))))
			             ((@@ (srfi srfi-1) remove)
			              string-null? (string-split
                                                    result #\newline)))))
	             (close-port port)
	             (format #f "~s" vars))
                   ")"))))
            (for_window "[title=\".* - Emacs Client\"]"
                        floating enable,
                        resize set 80 ppt 80 ppt)))))))

  (feature
   (name 'emacs)
   (values (append
	    `((emacs . #t))
	    (make-feature-values emacs-editor emacs-client
                                 emacs-client-create-frame
                                 emacs-client-no-wait
                                 emacs-server-mode?)))
   (home-services-getter emacs-home-services)))

(define* (feature-emacs-appearance
          #:key
          (margin 8))
  "Make Emacs looks modern and minimalistic."
  (ensure-pred integer? margin)

  (define emacs-f-name 'appearance)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (list
     (elisp-configuration-service
      emacs-f-name
      `((set-default 'cursor-type  '(bar . 1))
        (blink-cursor-mode 0)
        (setq-default cursor-in-non-selected-windows nil)

        (custom-set-variables '(window-divider-default-right-width ,margin))

        (require 'modus-themes)
        (setq modus-themes-scale-headings t)
	(load-theme 'modus-operandi t)

        ;; (setq header-line-format (delete 'mode-line-modes header-line-format))
        (setq mode-line-modes
              (let ((recursive-edit-help-echo "Recursive edit, type C-M-c to get out"))
                (list (propertize "%[" 'help-echo recursive-edit-help-echo)
	              "("
	              `(:propertize ("" mode-name)
			            help-echo "Major mode\n\
mouse-1: Display major mode menu\n\
mouse-2: Show help for major mode\n\
mouse-3: Toggle minor modes"
			            mouse-face mode-line-highlight
			            local-map ,mode-line-major-mode-keymap)
	              '("" mode-line-process)
	              ")"
	              (propertize "%]" 'help-echo recursive-edit-help-echo)
	              " ")))
        (custom-set-faces
         `(git-gutter-fr:modified
           ((t (:foreground "blue" :background "white"))))
         `(git-gutter-fr:added
           ((t (:foreground "green" :background "white"))))
         `(git-gutter-fr:deleted
           ((t (:foreground "red" :background "white")))))

        (defun rde--set-divider-faces ()
          (custom-set-faces
              `(window-divider
                ((t (:foreground ,(face-background 'default)))))
              `(window-divider-first-pixel
                ((t (:foreground ,(face-background 'default)))))
              `(window-divider-last-pixel
                ((t (:foreground ,(face-background 'default)))))))

        (if (daemonp)
            (add-hook 'after-make-frame-functions
                      (lambda (frame)
                        (with-selected-frame frame (rde--set-divider-faces))))
            (rde--set-divider-faces))
        (window-divider-mode))
      #:early-init
      `(,#~"\n;; Prevent the glimpse of un-styled Emacs by disabling \
these UI elements early."
        (push '(menu-bar-lines . 0) default-frame-alist)
        (push '(tool-bar-lines . 0) default-frame-alist)
        (push '(vertical-scroll-bars) default-frame-alist)
        (push '(internal-border-width . ,margin) default-frame-alist)

        ,#~""
        (setq-default fringes-outside-margins t)
        (setq-default left-margin-width 1)
        (setq-default right-margin-width 1)

        ,#~""
        (setq use-dialog-box nil)
        (setq use-file-dialog nil)
        (setq inhibit-startup-screen t)

        ,#~"\n;; Move modeline to the top"
        (setq-default header-line-format mode-line-format)
        (setq-default mode-line-format nil))
      #:elisp-packages (list emacs-modus-themes))))

  (feature
   (name f-name)
   (values `((,f-name . #t)
             (emacs-margin . ,margin)))
   (home-services-getter get-home-services)))


(define (strip-emacs-name p)
  (let ((name (package-name p)))
    (string->symbol
     (if (string-prefix? "emacs-" name)
         (string-drop name (string-length "emacs-"))
         name))))

(define* (feature-emacs-input-methods
	  #:key
          (enable-reverse-im #f)
	  (default-input-method "cyrillic-dvorak")
	  (input-method-packages (list emacs-cyrillic-dvorak-im)))
  "Configure input-method for GNU Emacs.  Allows to use other layouts
with emacs, whithout losing ability to use keybindings.  Supported
both Emacsy toggle-input-method (C-\\) and system layout switching by
utilizing reverse-im package."

  (define emacs-f-name 'input-method)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (list
     (elisp-configuration-service
      emacs-f-name
      `((with-eval-after-load
	 'mule
         (setq-default mode-line-mule-info nil)
         ;; Feels a little hacky, but mule-related hooks are
         ;; inconsistent and cursor not changed back in some cases.
         (add-hook 'post-command-hook
                   '(lambda ()
                      (set-cursor-color
                       (if current-input-method "DarkOrange1" "black"))))

         ,@(map (lambda (x) `(require ',(strip-emacs-name x)))
                input-method-packages)

	 (setq default-input-method ,default-input-method)
         (define-key global-map (kbd "s-SPC") 'toggle-input-method))

	,@(if enable-reverse-im
              `((add-hook 'after-init-hook 'reverse-im-mode)
                (with-eval-after-load
	         'reverse-im
	         (setq reverse-im-input-methods ,default-input-method)))
            '()))
      #:elisp-packages `(,@(if enable-reverse-im (list emacs-reverse-im) '())
                         ,@input-method-packages))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))


(define* (feature-emacs-erc
	  #:key
	  ;; (emacs-client? #f)
	  (erc-server "irc.libera.chat")
	  (erc-port 6697)
	  (erc-nick #f)
	  (erc-autojoin-channels-alist '()))
  "Configure GNU Emacs IRC client."
  (ensure-pred string? erc-server)
  (ensure-pred integer? erc-port)
  (ensure-pred maybe-string? erc-nick)
  (ensure-pred list? erc-autojoin-channels-alist)

  (define emacs-f-name 'erc)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (require-value 'emacs-client-create-frame config)
    (define emacs-cmd (get-value 'emacs-client-create-frame config))
    (list
     (elisp-configuration-service
      emacs-f-name
      `((with-eval-after-load
	 'erc
	 (setq erc-server ,erc-server)
	 (setq erc-port ,erc-port)
	 ,@(if erc-nick `((setq erc-nick ,erc-nick)) '())
	 (setq erc-autojoin-channels-alist
	       ',erc-autojoin-channels-alist)

	 (setq erc-fill-static-center 14)
	 (setq erc-fill-function 'erc-fill-static)
	 (setq erc-fill-column 86)

	 (setq erc-track-visibility nil))))
     (emacs-xdg-service
      emacs-f-name
      "Emacs (Client) [IRC]"
      #~(system* #$emacs-cmd "--eval" "(erc-tls)"))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))

(define* (feature-emacs-telega)
  "Configure telega.el for GNU Emacs"
  (define emacs-f-name 'telega)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (require-value 'emacs-client-create-frame config)
    (define emacs-cmd (get-value 'emacs-client-create-frame config))
    (define xdg-gexp
      #~(system*
         #$emacs-cmd
         "--eval"
         (string-append
	  "(progn
(set-frame-name \"Telega - Emacs Client\")
(if (and (boundp 'telega--status) (equal telega--status \"Ready\"))
 (telega-browse-url \"" (car (cdr (command-line))) "\")"
 "
 (telega)
 (add-hook 'telega-ready-hook
  (lambda ()
   (telega-browse-url \"" (car (cdr (command-line))) "\")))"
   "))")))

    (list
     (elisp-configuration-service
      emacs-f-name
      `((define-key global-map (kbd "C-c a t") 'telega)

        (with-eval-after-load
	 'telega

         (define-key telega-chat-mode-map (kbd "s-B") 'telega-chat-with)
	 (define-key telega-root-mode-map (kbd "s-B") 'telega-chat-with)
         (setq telega-emoji-company-backend 'telega-company-emoji)
         (defun my-telega-chat-mode ()
           (set (make-local-variable 'company-backends)
                (append (list telega-emoji-company-backend
                              'telega-company-username
                              'telega-company-hashtag)
                        (when (telega-chat-bot-p telega-chatbuf--chat)
                          '(telega-company-botcmd))))
           (company-mode 1))
         (add-hook 'telega-chat-mode-hook 'my-telega-chat-mode)

	 (setq telega-completing-read-function completing-read-function)))
      #:elisp-packages (list emacs-telega))

     (emacs-xdg-service emacs-f-name "Emacs (Client) [tg:]" xdg-gexp
                        #:default-for '(x-scheme-handler/tg))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))


(define* (feature-emacs-pdf-tools)
  "Configure pdf-tools, to work with pdfs inside Emacs."
  (define emacs-f-name 'pdf-tools)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (define emacs-cmd (get-value 'emacs-client-create-frame config))
    (define xdg-gexp
      #~(system*
         #$emacs-cmd
         (car (cdr (command-line)))))
    (list
     (elisp-configuration-service
      emacs-f-name
      `((custom-set-variables '(pdf-view-use-scaling t))
        (autoload 'pdf-view-mode "pdf-view" "")
        (add-to-list 'auto-mode-alist '("\\.[pP][dD][fF]\\'" . pdf-view-mode))
        (add-to-list 'magic-mode-alist '("%PDF" . pdf-view-mode))
        (add-hook 'pdf-view-mode-hook 'pdf-tools-enable-minor-modes)
        (with-eval-after-load
         'saveplace
         (require 'saveplace-pdf-view)))
      #:elisp-packages (list emacs-pdf-tools emacs-saveplace-pdf-view))
     (emacs-xdg-service emacs-f-name "Emacs (Client) [pdf]" xdg-gexp
                        #:default-for '(application/pdf))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))

(define* (feature-emacs-monocle)
  "Configure olivetti and helper functions for focused editing/reading."
  (define emacs-f-name 'monocle)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (list
     (elisp-configuration-service
      emacs-f-name
      `((custom-set-variables '(olivetti-body-width 80))

        (with-eval-after-load
         'hide-mode-line
         (custom-set-variables '(hide-mode-line-excluded-modes '())))

        (defun rde--match-modes (modes)
          "Check if current mode is derived from one of the MODES."
          (seq-filter 'derived-mode-p modes))

        (defun rde--turn-on-olivetti-mode ()
          (unless (memq major-mode '(minibuffer-mode which-key-mode))
            (olivetti-mode 1)))

        (define-globalized-minor-mode global-olivetti-mode
          olivetti-mode rde--turn-on-olivetti-mode
          :require 'olivetti-mode
          :group 'olivetti)

        (defvar rde--monocle-previous-window-configuration nil
          "Window configuration for restoring on monocle exit.")

        (defun rde-toggle-monocle (arg)
          "Make window occupy whole frame if there are many windows. Restore
previous window layout otherwise.  With universal argument toggles
`global-olivetti-mode'."
          (interactive "P")

          (if arg
              (if (and global-olivetti-mode global-hide-mode-line-mode)
                  (progn
                   (global-hide-mode-line-mode -1)
                   (global-olivetti-mode -1))
                  (progn
                   (global-hide-mode-line-mode 1)
                   (global-olivetti-mode 1)))
              (if (one-window-p)
                  (if rde--monocle-previous-window-configuration
	              (let ((cur-buffer (current-buffer)))
                        (set-window-configuration
                         rde--monocle-previous-window-configuration)
	                (setq rde--monocle-previous-window-configuration nil)
                        (switch-to-buffer cur-buffer)))
                  (setq rde--monocle-previous-window-configuration
                        (current-window-configuration))
                  (delete-other-windows))))

        (define-key global-map (kbd "C-c t o") 'olivetti-mode)
        (define-key global-map (kbd "C-c T o") 'global-olivetti-mode)
        (define-key global-map (kbd "C-c t m") 'hide-mode-line-mode)
        (define-key global-map (kbd "C-c T m") 'global-hide-mode-line-mode)
	(define-key global-map (kbd "s-f") 'rde-toggle-monocle))
      #:elisp-packages (list emacs-olivetti emacs-hide-header-line))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))


(define* (feature-emacs-dired)
  "Configure dired, the Emacs' directory browser and editor."
  (define emacs-f-name 'dired)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (define emacs-cmd (get-value 'emacs-client-create-frame config))
    (define xdg-gexp
      #~(system*
         #$emacs-cmd
         "--eval"
         (string-append
	  "(dired \"" (car (cdr (command-line))) "\")")))
    (list
     (elisp-configuration-service
      emacs-f-name
      `((with-eval-after-load
         'dired
         (setq dired-dwim-target t)
         (setq dired-listing-switches "-l --time-style=long-iso -h -AG")
         (add-hook 'dired-mode-hook 'dired-hide-details-mode)
         (setq dired-hide-details-hide-symlink-targets nil))))
     (emacs-xdg-service emacs-f-name "Emacs (Client) [file:]" xdg-gexp
                        #:default-for '(inode/directory))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))

(define* (feature-emacs-eshell)
  "Configure Eshell, the Emacs shell."
  (define emacs-f-name 'eshell)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (list
     (elisp-configuration-service
      emacs-f-name
      `((define-key global-map (kbd "s-e") 'eshell)
        (with-eval-after-load
         'eshell
         (add-hook
          'eshell-hist-mode-hook
          (lambda ()
            (when (fboundp 'consult-history)
              (define-key eshell-hist-mode-map (kbd "M-r") 'consult-history))))

         ;;; <https://www.emacswiki.org/emacs/AnsiColor#h5o-2>
         (add-hook 'eshell-preoutput-filter-functions 'ansi-color-filter-apply)

         (defun switch-to-prev-buffer-or-eshell (arg)
           (interactive "P")
           (if arg
               (eshell arg)
               (switch-to-buffer (other-buffer (current-buffer) 1))
               ;; (switch-to-prev-buffer)
               ))

         (add-hook
          'eshell-mode-hook
          (lambda ()
            (if envrc-global-mode
                (add-hook 'envrc-mode-hook (lambda () (setenv "PAGER" "")))
                (setenv "PAGER" ""))

            (eshell/alias "e" "find-file $1")
            (eshell/alias "ee" "find-file-other-window $1")
            (eshell/alias "d" "dired $1")
            (with-eval-after-load
             'magit (eshell/alias "gd" "magit-diff-unstaged"))

            (define-key eshell-mode-map (kbd "s-e")
              'switch-to-prev-buffer-or-eshell))))))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))

(define* (feature-emacs-org
          #:key
          (org-directory "~/org")
          (org-rename-buffer-to-title #t))
  "Configure org-mode for GNU Emacs."
  (define emacs-f-name 'org)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (list
     (elisp-configuration-service
      emacs-f-name
      `((with-eval-after-load
         'org
	 (setq org-adapt-indentation nil)
	 (setq org-edit-src-content-indentation 0)
	 (setq org-startup-indented t)

         (setq org-outline-path-complete-in-steps nil)
         (setq org-refile-use-outline-path 'path)
         (setq org-refile-targets `((nil . (:maxlevel . 3))))

         (setq org-ellipsis "⤵")
         (set-face-attribute 'org-ellipsis nil
		             :inherit '(font-lock-comment-face default)
		             :weight 'normal)
         (setq org-hide-emphasis-markers t)

         (setq org-directory ,org-directory)
         (setq org-default-notes-file (concat org-directory "/todo.org"))

         (define-key org-mode-map (kbd "C-c o n") 'org-num-mode)

         ;; <https://emacs.stackexchange.com/questions/54809/rename-org-buffers-to-orgs-title-instead-of-filename>
         (defun org+-buffer-name-to-title (&optional end)
           "Rename buffer to value of #+TITLE:.
If END is non-nil search for #+TITLE: at `point' and
delimit it to END.
Start an unlimited search at `point-min' otherwise."
           (interactive)
           (let ((case-fold-search t)
                 (beg (or (and end (point))
                          (point-min))))
             (save-excursion
              (when end
                (goto-char end)
                (setq end (line-end-position)))
              (goto-char beg)
              (when (re-search-forward
                     "^[[:space:]]*#\\+TITLE:[[:space:]]*\\(.*?\\)[[:space:]]*$"
                     end t)
                (rename-buffer (match-string 1)))))
           nil)

         (defun org+-buffer-name-to-title-config ()
           "Configure Org to rename buffer to value of #+TITLE:."
           (font-lock-add-keywords nil '(org+-buffer-name-to-title)))

         ,@(when org-rename-buffer-to-title
             '((add-hook 'org-mode-hook 'org+-buffer-name-to-title-config)))

         (with-eval-after-load 'notmuch (require 'ol-notmuch))))
      #:elisp-packages (list emacs-org emacs-org-contrib))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))

(define* (feature-emacs-elpher)
  "Configure elpher, the Emacs' gemini and gopher browser."
  (define emacs-f-name 'elpher)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (define emacs-cmd (get-value 'emacs-client-create-frame config))
    (define xdg-gexp
      #~(system*
         #$emacs-cmd
         "--eval"
         (string-append
	  "(elpher-go \"" (car (cdr (command-line))) "\")")))
    (list
     (elisp-configuration-service
      emacs-f-name
      `((autoload 'elpher-go "elpher"))
      #:elisp-packages (list emacs-elpher))
     (emacs-xdg-service emacs-f-name "Emacs (Client) [gemini:]" xdg-gexp
                        #:default-for '(x-scheme-handler/gemini))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))

(define* (feature-emacs-git)
  "Configure git-related utilities for GNU Emacs, including magit,
git-link, git-timemachine."
  (define emacs-f-name 'git)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (list
     (elisp-configuration-service
      emacs-f-name
      `((custom-set-variables '(git-link-use-commit t)
                              '(git-gutter:lighter " GG"))

        (define-key global-map (kbd "C-c t g") 'git-gutter-mode)
        (define-key global-map (kbd "C-c T g") 'global-git-gutter-mode)
        (define-key global-map (kbd "s-g") 'git-gutter-transient)

        (with-eval-after-load
         'git-gutter
         (require 'git-gutter-fringe)

         (add-to-list 'git-gutter:update-hooks 'focus-in-hook)
         (add-to-list 'git-gutter:update-commands 'other-window)

         (add-hook 'magit-post-stage-hook 'git-gutter:update-all-windows)
         (add-hook 'magit-post-unstage-hook 'git-gutter:update-all-windows)

         (defun yes-or-no-p->-y-or-n-p (orig-fun &rest r)
           (cl-letf (((symbol-function 'yes-or-no-p) 'y-or-n-p))
                    (apply orig-fun r)))

         (dolist (fn '(git-gutter:stage-hunk git-gutter:revert-hunk))
                 (advice-add fn :around 'yes-or-no-p->-y-or-n-p))

         (defadvice git-gutter:stage-hunk (around auto-confirm compile activate)
           (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest args) t)))
                    ad-do-it))

         (dolist (fringe '(git-gutter-fr:added
                           git-gutter-fr:modified))
                 (define-fringe-bitmap fringe (vector 8) nil nil '(top repeat)))
         (define-fringe-bitmap 'git-gutter-fr:deleted
           (vector 8 12 14 15)
           nil nil 'bottom)))
      #:elisp-packages (list emacs-magit emacs-magit-todos
                             emacs-git-link emacs-git-timemachine
                             emacs-git-gutter emacs-git-gutter-fringe
                             emacs-git-gutter-transient))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))

(define* (feature-emacs-which-key)
  "Configure which-key."
  (define emacs-f-name 'which-key)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (list
     (elisp-configuration-service
      emacs-f-name
      '((require 'which-key)
        (which-key-mode 1)
        (define-key global-map (kbd "C-h C-k") 'which-key-show-top-level))
      #:elisp-packages (list emacs-which-key))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))


;; TODO: Move font record to apropriate module
(use-modules (rde features fontutils))

;; TODO: Can be useful to have different presets for different
;; environments.  For easier and faster switching.
(define* (feature-emacs-faces)
  "Configure faces for GNU Emacs."

  (define emacs-f-name 'faces)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (require-value 'fonts config)
    (define font-monospace (get-value 'font-monospace config))
    (define font-sans      (get-value 'font-sans      config))
    (define font-serif     (get-value 'font-serif     config))

    (list
     (elisp-configuration-service
      emacs-f-name
      `((with-eval-after-load
	 'faces
	 (let* ((mono-fn ,(font-name font-monospace))
		(sans-fn ,(font-name font-sans))
		(serif-fn ,(font-name font-serif))
		(mono (font-spec
		       :name ,(font-name font-monospace)
                       ;; For some reason pgtk emacs has much smaller
                       ;; font than alacritty with the same size value
		       :size   ,(+ 3 (font-size font-monospace))
		       :weight ',(or (font-weight font-monospace) 'normal)))
		;; For people coming here years later, only
		;; face which can contain size or integer
		;; height is default, everything else should
		;; set only family or relative height
		;; (decimal value), the font-spec even
		;; without height/size shouldn't be used.
		;; Otherwise text-adjust and other stuff can
		;; be broken.
		(faces `((default ((t (:font ,mono))))
			 (fixed-pitch ((t (:family ,mono-fn))))
			 (button ((t (:inherit (fixed-pitch)))))
			 (variable-pitch ((t (:family ,serif-fn)))))))
	   (dolist (face faces)
		   (custom-set-faces face))

	   (dolist (face faces)
		   (put (car face) 'saved-face nil))))))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))


(define* (feature-emacs-completion)
  "Configure completion system for GNU Emacs."
  (define emacs-f-name 'completion)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (list
     (elisp-configuration-service
      emacs-f-name
      `((with-eval-after-load
	 'minibuffer

         (setq completion-styles '(orderless))
	 (setq completion-category-overrides
	       '((file (styles . (partial-completion)))))
         (setq completion-in-region-function 'consult-completion-in-region)
	 (setq enable-recursive-minibuffers t)

         (setq resize-mini-windows nil)

         ;; MAYBE: Make transient use child-frame:
         ;; https://github.com/magit/transient/issues/102
         (add-hook 'after-init-hook 'mini-frame-mode)
         (with-eval-after-load
          'mini-frame
          (custom-set-faces
           '(child-frame-border
             ;; TODO: inherit ,(face-attribute 'default :foreground)
             ((t (:background "#000000")))))
          (put 'child-frame-border 'saved-face nil)

          (custom-set-variables
           '(mini-frame-show-parameters
             (lambda ()
               `((top . 0.2)
                 (width . 0.8)
                 (left . 0.5)
                 (child-frame-border-width . 1))))
           '(mini-frame-detach-on-hide nil)
           '(mini-frame-color-shift-step 0)
           '(mini-frame-advice-functions '(read-from-minibuffer
                                           ;; read-string
                                           save-some-buffers yes-or-no-p))
           '(mini-frame-ignore-commands '()))))

	(custom-set-variables
         '(savehist-file (concat (or (getenv "XDG_CACHE_HOME") "~/.cache")
		                 "/emacs/history")))
	(add-hook 'after-init-hook 'savehist-mode)

        (define-key global-map (kbd "s-.") 'embark-act)
	(with-eval-after-load
	 'embark
         ;;; TODO: Enable it when user-rde-unexperienced?
         ;; (setq embark-prompter 'embark-completing-read-prompter)
         (require 'embark-consult))

        (autoload 'consult-customize "consult" "" nil 'macro)

        (progn
         (define-key minibuffer-local-map (kbd "M-r") 'consult-history)
	 (define-key global-map (kbd "M-y") 'consult-yank-pop)
         (define-key global-map (kbd "s-B") 'consult-buffer)
         (define-key minibuffer-local-map (kbd "s-B") 'embark-become)
         ;; (define-key global-map (kbd "M-.") 'embark-dwim)

         (define-key global-map (kbd "M-g g") 'consult-goto-line)
         (define-key global-map (kbd "M-g M-g") 'consult-goto-line)
         (define-key global-map (kbd "M-g o") 'consult-outline)
         (define-key global-map (kbd "M-g i") 'consult-imenu)
         (define-key global-map (kbd "M-g m") 'consult-mark)

         (define-key global-map (kbd "M-s f") 'consult-find)
         (define-key global-map (kbd "M-s g") 'consult-ripgrep)
         (define-key global-map (kbd "M-s e") 'consult-isearch)
         (define-key global-map (kbd "M-s l") 'consult-line)
         (define-key global-map (kbd "C-S-s") 'consult-line)

         (define-key isearch-mode-map (kbd "M-e") 'consult-isearch)
         (define-key isearch-mode-map (kbd "M-s e") 'consult-isearch)
         (define-key isearch-mode-map (kbd "M-s l") 'consult-line)
         (define-key isearch-mode-map (kbd "C-S-s") 'consult-line)

         (define-key global-map (kbd "C-c b b") 'consult-bookmark)
         ;; MAYBE: Move to feature-emacs-buffers/windows
         (define-key minibuffer-local-map (kbd "s-b") 'exit-minibuffer)
         (define-key global-map (kbd "s-b") 'switch-to-buffer)
         (define-key global-map (kbd "s-w") 'kill-current-buffer)
	 (define-key global-map (kbd "s-o") 'other-window))

        (with-eval-after-load
	 'consult
         (consult-customize consult-line :inherit-input-method t))

        (add-hook 'after-init-hook 'marginalia-mode)
        (add-hook 'after-init-hook 'vertico-mode)
	(with-eval-after-load
         'vertico
         (custom-set-variables '(vertico-cycle t))))
      #:elisp-packages
      (list emacs-orderless emacs-marginalia
	    emacs-vertico emacs-mini-frame
            emacs-pcmpl-args
            emacs-consult emacs-embark))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))

(define* (feature-emacs-project)
  "Configure project.el for GNU Emacs."

  (define emacs-f-name 'project)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (list
     (elisp-configuration-service
      emacs-f-name
      ;; TODO: https://github.com/muffinmad/emacs-ibuffer-project
      ;; MAYBE: Rework the binding approach
      `((add-hook 'after-init-hook
                  (lambda ()
                    (define-key global-map (kbd "s-p") project-prefix-map)))
        (with-eval-after-load
	 'project
	 (with-eval-after-load
	  'consult
	  (setq consult-project-root-function
		(lambda ()
		  (when-let (project (project-current))
			    (car (project-roots project)))))))))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))

(define* (feature-emacs-perspective)
  "Configure perspective.el to group/isolate buffers per frames.  Make
emacsclient feels more like a separate emacs instance."

  (define emacs-f-name 'perspective)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (list
     (elisp-configuration-service
      emacs-f-name
      `((add-hook 'after-init-hook 'persp-mode)
        (custom-set-variables
         '(persp-show-modestring nil)
         '(persp-modestring-dividers '(" [" "]" "|"))))
      #:elisp-packages (list emacs-perspective))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))

;; TODO: rewrite to states
(define* (feature-emacs-org-roam
	  #:key
	  (org-roam-directory #f))
  "Configure org-roam for GNU Emacs."
  (define (not-boolean? x) (not (boolean? x)))
  (ensure-pred not-boolean? org-roam-directory)

  (define emacs-f-name 'org-roam)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (list
     (elisp-configuration-service
      emacs-f-name
      `((setq org-roam-v2-ack t)

        (custom-set-variables
         '(org-roam-completion-everywhere t)
         '(org-roam-directory ,org-roam-directory))

        (with-eval-after-load 'org-roam (org-roam-setup))

	(define-key global-map (kbd "C-c n n") 'org-roam-buffer-toggle)
	(define-key global-map (kbd "C-c n f") 'org-roam-node-find)
	(define-key global-map (kbd "C-c n i") 'org-roam-node-insert))
      #:elisp-packages (list emacs-org-roam))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))


(define* (feature-emacs-keycast)
  "Show keybindings and related functions as you type."

  (define emacs-f-name 'keycast)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (list
     (elisp-configuration-service
      emacs-f-name
      `((with-eval-after-load
         'keycast
         (require 'moody)
         (setq keycast-window-predicate 'moody-window-active-p)
         (setq keycast-separator-width 1)
         (add-to-list 'global-mode-string mode-line-keycast))

        (autoload 'keycast--update "keycast")
        ;; <https://github.com/tarsius/keycast/issues/7#issuecomment-627604064>
        (define-minor-mode rde-keycast-mode
          "Show current command and its key binding in the mode line."
          :global t
          (if rde-keycast-mode
              (add-hook 'pre-command-hook 'keycast--update t)
              (progn
               (setq keycast--this-command nil)
               (setq keycast--this-command-keys nil)
               (setq keycast--command-repetitions 0)
               (remove-hook 'pre-command-hook 'keycast--update))))

        (define-key global-map (kbd "C-c t k") 'rde-keycast-mode)
        (define-key global-map (kbd "C-c T k") 'rde-keycast-mode))
      #:elisp-packages (list emacs-moody emacs-keycast))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))

;; TODO: feature-emacs-reasonable-keybindings
;; TODO: Fix env vars for emacs daemon
;; https://github.com/purcell/exec-path-from-shell
;; TODO: feature-emacs-epub https://depp.brause.cc/nov.el/
;; TODO: feature-series-tracker https://github.com/MaximeWack/seriesTracker
