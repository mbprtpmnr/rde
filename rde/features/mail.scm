(define-module (rde features mail)
  #:use-module (rde packages)
  #:use-module (rde features)
  #:use-module (rde features predicates)
  #:use-module (rde features emacs)
  #:use-module (gnu packages mail)
  #:use-module (gnu packages emacs-xyz)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu home-services)
  #:use-module (gnu home-services mail)
  #:use-module (gnu home-services mcron)

  #:use-module (srfi srfi-1)
  #:use-module (guix gexp)

  #:export (feature-mail-settings
            feature-emacs-message
            feature-isync
            feature-notmuch
            feature-msmtp
            feature-l2md

            mail-account
            mail-account-id
            mail-account-type
            mail-account-fqda
            mail-account-synchronizer
            mail-account-get-pass-cmd

            mailing-list
            mailing-list-id
            mailing-list-fqda
            mailing-list-synchronizer
            mailing-list-config

            %rde-notmuch-saved-searches)

  #:re-export (l2md-repo))


(define-configuration/no-serialization mail-account
  (id
   (symbol #f)
   "Something short to identify and distinguish a mail account.
@code{'work} or @code{'personal} for example.")
  ;; TODO: Add aliases?
  (type
   (symbol 'generic)
   "Type of the mail account.  Will be used in different serialization
scenarios, during generation of @file{mbsyncrc} for example.")
  (synchronizer
   (symbol 'isync)
   "Type of application to obtain emails.")
  (fqda
   (string #f)
   "Email address. @code{\"someone@example.com\"} for example.")
  (pass-cmd
   (maybe-string #f)
   "Command returning a password.  If value not provided @code{pass
show mail/$fqda} will be used, where @code{$fqda} is a value of fqda
field."))

(define (mail-account-get-pass-cmd mail-account)
  (if (mail-account-pass-cmd mail-account)
      (mail-account-pass-cmd mail-account)
      (string-append "pass show mail/" (mail-account-fqda mail-account))))


(define-configuration/no-serialization mailing-list
  (id
   (symbol #f)
   "Something short to identify and distinguish a mailing lists.
@code{'guix-devel} or @code{'guix-patches} for example.")
  (fqda
   (string #f)
   "Mailing list address. @code{\"guix-devel@gnu.org\"} for example.")
  (config
   (record #f)
   "Mailing list configuration. @code{(l2md-repo ...)} for example.")
  (synchronizer
   (symbol 'l2md)
   "Type of application to obtain mailing list."))

(define (list-of-mail-accounts? lst)
  (and (list? lst) (not (null? lst)) (any mail-account? lst)))

(define (list-of-mailing-lists? lst)
  (and (list? lst) (not (null? lst)) (any mailing-list? lst)))

(define (default-mail-directory-fn config)
  (string-append (get-value 'home-directory config)
                 ;; TODO: Uses XDG_STATE_HOME
                 ;; (get-value 'xdg-blablabla config)
                 "/mail"))

(define* (feature-mail-settings
          #:key
          (mail-accounts #f)
          (mailing-lists '())
          (mail-directory-fn default-mail-directory-fn))
  "Provide mail-accounts and mail-directory-fn for other mail-related
features."
  (ensure-pred list-of-mail-accounts? mail-accounts)
  (ensure-pred list-of-mailing-lists? mailing-lists)
  (ensure-pred procedure? mail-directory-fn)

  (define (get-home-services config)
    (list
     (simple-service
      'mail-settings-add-mailcap-file
      home-files-service-type
      `(("mailcap" ,(plain-file "mailcap" "text/*; xdg-open %s\n"))))))

  (feature
   (name 'mail-settings)
   (home-services-getter get-home-services)
   (values `((mail-settings . #t)
             (mail-accounts . ,mail-accounts)
             (mailing-lists . ,mailing-lists)
             (mail-directory-fn . ,mail-directory-fn)))))


(define* (feature-emacs-message)
  "Configure email sending capabilities provided by @file{message.el}."
	    feature-emacs-message

  (define emacs-f-name 'message)
  (define f-name (symbol-append 'emacs- emacs-f-name))

  (define (get-home-services config)
    (require-value 'emacs-client-create-frame config)
    (define emacs-cmd (get-value 'emacs-client-create-frame config))
    (define gpg-primary-key (get-value 'gpg-primary-key config))

    (list
     (elisp-configuration-service
      emacs-f-name
      `((eval-when-compile
         (require 'message)
         (require 'sendmail))
        (with-eval-after-load
	 'message

         (custom-set-variables
          '(sendmail-program "msmtp")
          '(message-send-mail-function 'message-send-mail-with-sendmail)
          '(message-sendmail-f-is-evil t)
          '(message-sendmail-extra-arguments '("--read-envelope-from")))

         (setq message-kill-buffer-on-exit t)

         ,@(if gpg-primary-key
             `((setq mml-secure-openpgp-signers '(,gpg-primary-key))
               ;; (setq mml-secure-openpgp-sign-with-sender t)
               (add-hook 'message-setup-hook 'mml-secure-message-sign-pgpmime))
             '())

         (setq message-citation-line-function
               'message-insert-formatted-citation-line)

         (custom-set-variables
          '(message-citation-line-format "On %Y-%m-%d %R, %N wrote:\n")
          `(message-auto-save-directory
	       ,(concat (or (getenv "XDG_CACHE_HOME") "~/.cache")
		        "/emacs/mail-drafts"))))))

     (emacs-xdg-service
      emacs-f-name
      "Emacs (Client) [mailto:]"
      #~(system*
         #$emacs-cmd "--eval"
	 (string-append
          "\
(progn
 (set-frame-name \"Reply to Email - Emacs Client\")
 (browse-url-mail \"" (cadr (command-line)) "\"))"))
      #:default-for '(x-scheme-handler/mailto))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))


(define* (feature-msmtp)
  "Configure msmtp MTA."
  (define (get-home-services config)
    (require-value 'mail-directory-fn config)
    (define mail-dir ((get-value 'mail-directory-fn config) config))
    (define queue-dir (string-append mail-dir "/queue"))
    (list
     (simple-service
      'msmtp-env-var-settings
      home-environment-variables-service-type
      `(("MSMTPQ_LOG" . "$XDG_LOG_HOME/msmtpq.log")
        ("MSMTPQ_QUEUE_DIR" . ,queue-dir)))
     (simple-service
      'msmtp-packages
      home-profile-service-type
      (list msmtp-latest))))

  (feature
   (name 'msmtp)
   (home-services-getter get-home-services)
   (values `((msmtp . #t)))))

(define* (feature-l2md)
  "Configure l2md MDA."
  (define (get-home-services config)
    (require-value 'mail-directory-fn config)
    (require-value 'mailing-lists config)
    (define mail-dir ((get-value 'mail-directory-fn config) config))
    (define mls (filter (lambda (x) (eq? (mailing-list-synchronizer x) 'l2md))
                        (get-value 'mailing-lists config)))
    (define (get-repo-config ml)
      (let ((repo-config (mailing-list-config ml)))
        (if (eq? (l2md-repo-maildir repo-config) 'disabled)
            (l2md-repo
             (inherit repo-config)
             (maildir (string-append
                       mail-dir "/lists/" (mailing-list-fqda ml) "/all")))
            repo-config)))
    ;; <https://git.kernel.org/pub/scm/linux/kernel/git/dborkman/l2md.git/about/>
    ;; Applying patches <https://git.kyleam.com/piem/about/>

    (list
     (service home-mcron-service-type
              (home-mcron-configuration
               (jobs (list #~(job '(next-hour)
                                  (lambda ()
                                    (setenv "DISPLAY" ":0")
                                    (system* "mbsync" "-a")
                                    (system* "l2md")))))))
     (service
      home-l2md-service-type
      (home-l2md-configuration
       (oneshot 1)
       (repos (map get-repo-config mls))))))

  (feature
   (name 'l2md)
   (home-services-getter get-home-services)
   (values `((l2md . #t)))))

(define (prep-str sym str)
  (symbol-append sym '- (string->symbol str)))

(define (isync-channel id local remote)
  `((Channel ,(prep-str id local))
    (Near ,(format #f ":~a-local:~a" id local))
    (Far ,(format #f ":~a-remote:~a" id remote))
    ,#~""))

(define (isync-group-with-channels id isync-mapping)
  (append
   (append-map
    (lambda (x) (isync-channel id (car x) (cdr x)))
    isync-mapping)
   `((Group ,(symbol-append id))
     ,@(map
        (lambda (x) (list 'Channel (prep-str id (car x))))
        isync-mapping)
     ,#~"")))

(define (generate-isync-serializer host folders-mapping)
  (define (isync-settings mail-directory mail-account)
    (let* ((id       (mail-account-id mail-account))
           (user     (mail-account-fqda mail-account))
           (pass-cmd (mail-account-get-pass-cmd mail-account)))
      `(,#~(string-append "# Account '" #$(symbol->string id)
                          " starts here")
        (IMAPAccount ,id)
        (Host ,host)
        (User ,user)
        (PassCmd ,pass-cmd)
        ;; (AuthMechs LOGIN)
        (SSLType IMAPS)
        ,#~""
        (IMAPStore ,(symbol-append id '-remote))
        (Account ,id)
        ,#~""
        (MaildirStore ,(symbol-append id '-local))
        (SubFolders Verbatim)
        (Path ,(string-append mail-directory "/accounts/" user "/"))
        (Inbox ,(string-append mail-directory "/accounts/" user "/inbox"))
        ,#~""
        ,@(isync-group-with-channels id folders-mapping))))
  isync-settings)

;; Directory names has lowercased spelling to match notmuch tags
(define gmail-folder-mapping
  '(("inbox"  . "INBOX")
    ("sent"   . "[Gmail]/Sent Mail")
    ("drafts" . "[Gmail]/Drafts")
    ("all"    . "[Gmail]/All Mail")
    ("trash"  . "[Gmail]/Trash")
    ("spam"   . "[Gmail]/Spam")))

(define gmail-isync-settings
  (generate-isync-serializer "imap.gmail.com" gmail-folder-mapping))

(define (generic-isync-settings mail-directory mail-account)
  `(,#~"# Do not know how to serialize generic accounts :("))

(define %default-isync-serializers
  `((gmail . ,gmail-isync-settings)
    (generic . ,generic-isync-settings)))

(define default-isync-global-settings
  `((Create Both)
    (Expunge Both)
    (SyncState *)
    ,#~""))

(define* (feature-isync
          #:key
          (mail-account-ids #f)
          (isync-global-settings default-isync-global-settings)
          (isync-serializers %default-isync-serializers)
          (isync-verbose #f))
  "Setup and configure isync.  If MAIL-ACCOUNT-IDS not provided use all
mail accounts.  ISYNC-VERBOSE controls output verboseness of
@file{mbsync}."
  (ensure-pred maybe-list? mail-account-ids)
  (ensure-pred list? isync-serializers)
  (ensure-pred list? isync-global-settings)

  ;; Sync mail deletion
  ;; https://notmuchmail.org/pipermail/notmuch/2016/023112.html
  ;; http://tiborsimko.org/mbsync-duplicate-uid.html

  ;; https://notmuchmail.org/emacstips/#index25h2

  (define (get-home-services config)
    (require-value 'mail-accounts config
                   "feature-isync can't operate without mail-accounts.")

    (let* ((mail-accounts
            (filter (lambda (x) (eq? (mail-account-synchronizer x) 'isync))
                    (get-value 'mail-accounts config)))
           (mail-directory-fn (get-value 'mail-directory-fn config))
           (mail-directory    (mail-directory-fn config)))

      (define (serialize-mail-acc mail-acc)
        ((assoc-ref isync-serializers (mail-account-type mail-acc))
         mail-directory mail-acc))

      (list
       (service
        home-isync-service-type
        (home-isync-configuration
         (config
          (append
           isync-global-settings
           (append-map serialize-mail-acc mail-accounts))))))))

  ;; MAYBE: Wrap it in a program-file to make it possible to call it
  ;; with system*
  (define (isync-synchronize-cmd-fn mail-acc)
    (string-append "mbsync "
                   (if isync-verbose "-V " "")
                   (symbol->string (mail-account-id mail-acc))))

  (feature
   (name 'isync)
   (values `((isync . #t)
             (isync-synchronize-cmd-fn . ,isync-synchronize-cmd-fn)))
   (home-services-getter get-home-services)))


(define (default-get-notmuch-configuration config)
  (require-value 'mail-settings config)
  (require-value 'full-name config)
  (define full-name (get-value 'full-name config))
  (define mail-accounts (get-value 'mail-accounts config))
  (define emails (map mail-account-fqda mail-accounts))
  (define ids    (map mail-account-id   mail-accounts))

  (define mail-directory ((get-value 'mail-directory-fn config) config))
  (define (mail-dir email) (string-append mail-directory "/" email))
  (define mail-directories (map mail-dir emails))

  (define (sync-cmd ma)
    ((get-value
      (symbol-append (mail-account-synchronizer ma) '-synchronize-cmd-fn)
      config)
     ma))

  (define sync-cmds (map sync-cmd mail-accounts))

  (define make-id-tag
    (map (lambda (x)
           (format
            #f "notmuch tag +~a -- path:accounts/~a/** and tag:new"
            (mail-account-id x) (mail-account-fqda x)))
         mail-accounts))

  (define tag-updates-post
    '("notmuch tag +inbox -- path:/accounts\\/.*\\/inbox/"
      "notmuch tag +draft -- path:/accounts\\/.*\\/drafts/"
      "notmuch tag +sent  -- path:/accounts\\/.*\\/sent/"
      "notmuch tag +trash -- path:/accounts\\/.*\\/trash/"
      "notmuch tag +spam  -- path:/accounts\\/.*\\/spam/"
      "notmuch tag +list  -- path:/lists\\/.*/"
      "notmuch tag +todo -inbox -sent  -- tag:inbox and tag:sent"
      ;; If file was moved out of folder on server remove respective tag
      "notmuch tag -inbox -- not path:/accounts\\/.*\\/inbox/ and tag:inbox"
      "notmuch tag -trash -- not path:/accounts\\/.*\\/trash/ and tag:trash"
      "notmuch tag -spam  -- not path:/accounts\\/.*\\/spam/  and tag:spam"

      "notmuch tag -new -- tag:new"))

  ;; (define tag-updates-post-insert
  ;;   "notmuch tag +sent -new -- path:/.*\\/sent/ and tag:new")

  (define (move-out-untagged-messages tag)
    "If tag was removed -> move out of the related folder."
    (format #f "for f in $(notmuch search --output=files \
'path:/.*\\/~a/ and not tag:~a' | grep '/~a/'); \
do mv -v $f \
$(echo $f | sed 's;/~a/;/all/;' | sed 's/,U=[0-9]*:/:/'); done"
            tag tag tag tag))

  (define* (move-in-tagged-messages
            tag
            #:optional (exclude-dir "nothing-will-match-this"))
    (format #f "for f in $(notmuch search --output=files \
'not path:/.*\\/~a/ and tag:~a' | grep -v \"/~a/\"); \
do mv -v $f \
$(echo $f | sed 's;/[[:alnum:]]*/cur/;/~a/cur/;' | sed 's/,U=[0-9]*:/:/'); done"
            tag tag exclude-dir tag))
  (define delete-deleted-messages
    "for f in $(notmuch search --output=files tag:deleted); do rm -v $f; done")

  (define move-rules
    (append
     (map move-out-untagged-messages '(inbox trash spam))
     (map move-in-tagged-messages '(trash spam))
     (list (move-in-tagged-messages 'inbox "all")
           delete-deleted-messages)))

  (home-notmuch-extension
   (pre-new
    (list
     (with-imported-modules '((guix build utils))
       #~(begin
           (map (@@ (guix build utils) mkdir-p) '#$mail-directories)
           (for-each system '#$move-rules)
           ;; (for-each system '#$sync-cmds)
           ))))
   (post-new
    (list
     #~(begin (for-each system '#$make-id-tag)
              (for-each system '#$tag-updates-post))))
   (config
    `((user ((name . ,full-name)
             (primary_email . ,(car emails))
             (other_email . ,(cdr emails))))
      (database ((path . ,mail-directory)
                 (mail_root . ,mail-directory)))
      (maildir ((synchronize_flags . true)))
      (search ((exclude_tags . (trash spam deleted))))
      (new ((tags . new)
            (ignore . (.mbsyncstate .uidvalidity
                       .mbsyncstate.new .mbsyncstate.journal))))))))

(define (notmuch-redefined-functions config)
  ;; Remove leading arrows for mails without threads
  ;; Make the width used by notmuch-jump prompt to be 80%
  `((defun rde-notmuch-tree-insert-tree (tree depth tree-status first last)
      "Insert the message tree TREE at depth DEPTH in the current thread.

A message tree is another name for a single sub-thread: i.e., a
message together with all its descendents."
      (let ((msg (car tree))
	    (replies (cadr tree)))
        (cond
         ((and (< 0 depth) (not last))
          (push "├" tree-status))
         ((and (< 0 depth) last)
          (push "└" tree-status))
         ((and (eq 0 depth) first last)
          ;; Choice between these two variants is a matter of taste.
          ;; (push "─" tree-status))
          (push " " tree-status))
         ((and (eq 0 depth) first (not last))
          (push "┬" tree-status))
         ((and (eq 0 depth) (not first) last)
          (push "└" tree-status))
         ((and (eq 0 depth) (not first) (not last))
          (push "├" tree-status)))
        (unless (eq 0 depth)
          (push (concat (if replies "┬" "─") ">") tree-status))
        (setq msg (plist-put msg :first (and first (eq 0 depth))))
        (setq msg (plist-put msg :tree-status tree-status))
        (setq msg (plist-put msg :orig-tags (plist-get msg :tags)))
        (notmuch-tree-goto-and-insert-msg msg)
        (pop tree-status)
        (pop tree-status)
        (if last
	    (push " " tree-status)
            (push "│" tree-status))
        (notmuch-tree-insert-thread replies (+ 1 depth) tree-status)))
    (advice-add 'notmuch-tree-insert-tree :override
                'rde-notmuch-tree-insert-tree)

    (defun rde-notmuch-jump (action-map prompt)
      "Interactively prompt for one of the keys in ACTION-MAP.

Displays a summary of all bindings in ACTION-MAP in the
minibuffer, reads a key from the minibuffer, and performs the
corresponding action.  The prompt can be canceled with C-g or
RET.  PROMPT must be a string to use for the prompt.  PROMPT
should include a space at the end.

ACTION-MAP must be a list of triples of the form
  (KEY LABEL ACTION)
where KEY is a key binding, LABEL is a string label to display in
the buffer, and ACTION is a nullary function to call.  LABEL may
be null, in which case the action will still be bound, but will
not appear in the pop-up buffer."
      (let* ((items (notmuch-jump--format-actions action-map))
	     ;; Format the table of bindings and the full prompt
	     (table
	      (with-temp-buffer
	       (notmuch-jump--insert-items
                (floor (* (frame-width) 0.8)) items)
	       (buffer-string)))
	     (full-prompt
	      (concat table "\n\n"
		      (propertize prompt 'face 'minibuffer-prompt)))
	     ;; By default, the minibuffer applies the minibuffer face to
	     ;; the entire prompt.  However, we want to clearly
	     ;; distinguish bindings (which we put in the prompt face
	     ;; ourselves) from their labels, so disable the minibuffer's
	     ;; own re-face-ing.
	     (minibuffer-prompt-properties
	      (notmuch-plist-delete
	       (copy-sequence minibuffer-prompt-properties)
	       'face))
	     ;; Build the keymap with our bindings
	     (minibuffer-map (notmuch-jump--make-keymap action-map prompt))
	     ;; The bindings save the the action in notmuch-jump--action
	     (notmuch-jump--action nil))
        ;; Read the action
        (read-from-minibuffer full-prompt nil minibuffer-map)
        ;; If we got an action, do it
        (when notmuch-jump--action
          (funcall notmuch-jump--action))))
    (advice-add 'notmuch-jump :override 'rde-notmuch-jump)))

(define %rde-notmuch-saved-searches
  '((:name "TODO" :query "tag:todo" :key "t")
    (:name "Inbox" :query "tag:inbox" :key "i"
     :query "tag:inbox and tag:unread" :sort-order oldest-first)
    (:name "Watching" :query "thread:{tag:watch} and tag:unread" :key "w")
    (:name "Drafts" :query "tag:draft" :key "d")
    (:name "Flagged" :query "tag:flagged" :key "f")
    (:name "Sent" :query "tag:sent" :key "s")
    (:name "All mail" :query "*" :key "a")))

(define* (feature-notmuch
          #:key
          (get-notmuch-configuration default-get-notmuch-configuration)
          (notmuch-saved-searches %rde-notmuch-saved-searches))
  "Configure notmuch and Emacs UI for it if emacs enabled."
  (ensure-pred procedure? get-notmuch-configuration)

  (define f-name 'notmuch)

  (define (get-home-services config)
    (define emails (map mail-account-fqda (get-value 'mail-accounts config)))

    (define fcc-dirs
      (map (lambda (x) (cons x (string-append "accounts/" x "/sent"))) emails))

    (list
     (simple-service
      'notmuch-service
      home-notmuch-service-type
      (get-notmuch-configuration config))
     (when (get-value 'emacs config)
       (elisp-configuration-service
        f-name
        ;; https://protesilaos.com/dotemacs/#h:a196812e-1644-4536-84ba-687366867def
        ;; https://codeberg.org/jao/elibs/src/branch/main/notmuch.org
        `((autoload 'notmuch-mua-new-mail "notmuch-mua")
          (define-key global-map (kbd "C-c a n") 'notmuch)
          ;; (define-key global-map (kbd "C-c m s") 'consult-notmuch-tree)
          (define-key global-map (kbd "M-s n") 'consult-notmuch-tree)
          (define-key global-map (kbd "C-x m") 'notmuch-mua-new-mail)
          (define-key global-map (kbd "s-m") 'notmuch-jump-search)
          (setq notmuch-saved-searches ',notmuch-saved-searches)
          (setq notmuch-search-oldest-first nil)

          (with-eval-after-load
           'notmuch-mua
           ;; (setq sendmail-program "true")
           (require 'notmuch))

          (with-eval-after-load
           'notmuch
           (setq notmuch-fcc-dirs ',fcc-dirs)
           (setq notmuch-identities ',emails)
           (setq notmuch-address-use-company nil)

           (setq notmuch-unthreaded-show-out nil)

           (setq notmuch-show-empty-saved-searches t)
           (setq notmuch-mua-cite-function 'message-cite-original-without-signature)

           (setq rde-notmuch-todo-tags '("+todo" "-inbox"))
           (setq rde-notmuch-spam-tags '("+spam" "-inbox"))
           (setq rde-notmuch-trash-tags '("+trash" "-inbox" "-draft"))
           (setq rde-notmuch-delete-tags '("+deleted" "-inbox" "-draft"))
           (setq notmuch-archive-tags '("-inbox" "-todo"))
           (setq notmuch-tagging-keys
                 '(("a" notmuch-archive-tags "Archive")
                   ("r" notmuch-show-mark-read-tags "Mark read")
                   ("f" ("+flagged") "Flag (favorite)")
                   ;; ("w" ("+watch") "Watch")
                   ("t" rde-notmuch-todo-tags "Mark as todo")
                   ("s" rde-notmuch-spam-tags "Mark as spam")
                   ("d" rde-notmuch-trash-tags "Trash")
                   ("D" rde-notmuch-delete-tags "Delete")))

           (define-key notmuch-search-mode-map "w"
             (lambda ()
               (interactive)
               (notmuch-tag
                (concat
                 "id:" (car (notmuch-query-get-message-ids
                             (notmuch-search-find-thread-id))))
                (list "+watch"))
               (notmuch-tree-next-message)))
           (define-key notmuch-search-mode-map "d"
             (lambda ()
               (interactive)
               (notmuch-search-add-tag rde-notmuch-trash-tags)
               (notmuch-tree-next-message)))
           (define-key notmuch-search-mode-map "D"
             (lambda ()
               (interactive)
               (notmuch-search-add-tag rde-notmuch-delete-tags)
               (notmuch-tree-next-message)))
           (define-key notmuch-search-mode-map "T"
             (lambda ()
               (interactive)
               (notmuch-search-add-tag rde-notmuch-todo-tags)
               (notmuch-tree-next-message)))

           (defun rde-notmuch-show-view-html-part ()
             "Open the text/html part of the current message using
`notmuch-show-view-part'."
             (interactive)
             (save-excursion
              (goto-char
               (prop-match-beginning
                (text-property-search-forward
                 :notmuch-part
                 "text/html"
                 (lambda (value notmuch-part)
                   (equal (plist-get notmuch-part :content-type) value)))))
              (notmuch-show-view-part)))
           (define-key notmuch-show-part-map "h" 'rde-notmuch-show-view-html-part)

           ,@(notmuch-redefined-functions config)

           (setq notmuch-search-result-format
                 '(("date" . "%12s ")
                   ("count" . "%-7s ")
                   ("authors" . "%-20s ")
                   ("subject" . "%-80s  ")
                   ("tags" . "(%s)")))
           (setq notmuch-tree-result-format
                 '(("date" . "%12s  ")
                   ("authors" . "%-20s")
                   ((("tree" . "%s")
                     ("subject" . "%s"))
                    . " %-88s ")
                   ("tags" . "(%s)")))
           (setq notmuch-unthreaded-result-format
                 '(("date" . "%12s  ")
                   ("authors" . "%-20s")
                   ((("subject" . "%s"))
                    . " %-88s ")
                   ("tags" . "(%s)")))

           (defun rde--notmuch-refresh-buffer (&optional _)
             "Wrapper around `notmuch-refresh-this-buffer', which accepts
optional arguments to use the function inside hook."
             (notmuch-refresh-this-buffer))

           (defun rde--add-notmuch-hello-hooks ()
             "Add mode local hooks for notmuch-hello buffers."
             (add-hook 'window-size-change-functions 'rde--notmuch-refresh-buffer))

           (add-hook 'notmuch-hello-mode-hook 'rde--add-notmuch-hello-hooks)

           (setq notmuch-show-logo nil))

          (with-eval-after-load 'magit (require 'git-email-magit)))
        #:elisp-packages (list emacs-git-email-latest emacs-consult-notmuch)))))

  (feature
   (name f-name)
   (values `((,f-name . #t)))
   (home-services-getter get-home-services)))

;; Think about delayed email sending
