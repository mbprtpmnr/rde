(define-module (gnu home-services xdg)
  #:use-module (gnu services configuration)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu home-services)
  #:use-module (gnu home-services files)
  #:use-module (gnu home-services-utils)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (guix i18n)
  #:use-module (guix diagnostics)
  #:use-module ((guix import utils) #:select (flatten))
  #:use-module (ice-9 string-fun)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-26)
  #:use-module (rnrs enums)


  #:export (home-xdg-base-directories-service-type
            home-xdg-base-directories-configuration

            home-xdg-user-directories-service-type
            home-xdg-user-directories-configuration

            xdg-desktop-entry
            home-xdg-mime-applications-service-type
            home-xdg-mime-applications-configuration))

;;; Commentary:
;;
;; This module contains services related to XDG directories and
;; applications.
;;
;; - XDG base directories
;; - XDG user directories
;; - XDG MIME applications
;;
;; TODO: Add proper docs for XDG
;; TODO: Deal with state/log directories
;;
;;; Code:


;;;
;;; XDG base directories.
;;;

(define (serialize-path field-name val) "")
(define path? string?)

(define-configuration home-xdg-base-directories-configuration
  (cache-home
   (path "$HOME/.cache")
   "Base directory for programs to store non-essential user data, like
cache.")
  (config-home
   (path "$HOME/.config")
   "Base directory for programs to store configuration files.")
  (data-home
   (path "$HOME/.local/share")
   "Base directory for programs to store user data, like history."))

(define (home-xdg-base-directories-environment-vars-service config)
  `(("XDG_CACHE_HOME" . ,(home-xdg-base-directories-configuration-cache-home
                           config))
    ("XDG_CONFIG_HOME" . ,(home-xdg-base-directories-configuration-config-home
                             config))
    ("XDG_DATA_HOME" . ,(home-xdg-base-directories-configuration-data-home
                           config))))

(define home-xdg-base-directories-service-type
  (service-type (name 'home-xdg-base-directories)
                (extensions
                 (list (service-extension
                        home-environment-vars-service-type
                        home-xdg-base-directories-environment-vars-service)))
                (default-value (home-xdg-base-directories-configuration))
                (description "Configure XDG base directories.")))

(define (generate-home-xdg-base-directories-documentation)
  (generate-documentation
   `((home-xdg-base-directories-configuration
      ,home-xdg-base-directories-configuration-fields))
   'home-xdg-base-directories-configuration))


;;;
;;; XDG user directories.
;;;

(define (serialize-string field-name val)
  ;; The path has to be quoted
  (format #f "XDG_~a_DIR=\"~a\"\n"
          (symbol->snake-case field-name 'upper) val))

(define-configuration home-xdg-user-directories-configuration
  (desktop
   (string "$HOME/Desktop")
   "Default ``desktop'' directory, this is what you see on your
desktop when using a desktop environment,
e.g. GNOME (@pxref{XWindow,,,guix.info}).")
  (documents
   (string "$HOME/Documents")
   "Default directory to put documents like PDFs.")
  (download
   (string "$HOME/Downloads")
   "Default directory downloaded files, this is where your Web-broser
will put downloaded files in.")
  (music
   (string "$HOME/Music")
   "Default directory for audio files.")
  (pictures
   (string "$HOME/Pictures")
   "Default directory for pictures and images.")
  (publicshare
   (string "$HOME/Public")
   "Default directory for shared files, which can be accessed by other
users on local machine or via network.")
  (templates
   (string "$HOME/Templates")
   "Default directory for templates.  They can be used by graphical
file manager or other apps for creating new files with some
pre-populated content.")
  (videos
   (string "$HOME/Videos")
   "Default directory for videos."))

(define (home-xdg-user-directories-files-service config)
  `(("config/user-dirs.conf"
     ,(mixed-text-file
       "user-dirs.conf"
       "enabled=False\n"))
    ("config/user-dirs.dirs"
     ,(mixed-text-file
       "user-dirs.dirs"
      (serialize-configuration
       config
       home-xdg-user-directories-configuration-fields)))))

(define (home-xdg-user-directories-on-reconfigure config)
  (let ((dirs (map (lambda (field)
		     ((configuration-field-getter field) config))
		   home-xdg-user-directories-configuration-fields)))
    #~(let ((ensure-dir
	     (lambda (path)
	       (mkdir-p
		((@@ (ice-9 string-fun) string-replace-substring)
		 path "$HOME" (getenv "HOME"))))))
	(display "Creating XDG user directories...")
	(map ensure-dir '#$dirs)
	(display " done\n"))))

(define home-xdg-user-directories-service-type
  (service-type (name 'home-xdg-user-directories)
                (extensions
                 (list (service-extension
                        home-files-service-type
                        home-xdg-user-directories-files-service)
                       (service-extension
                        home-run-on-reconfigure-service-type
                        home-xdg-user-directories-on-reconfigure)))
                (default-value (home-xdg-user-directories-configuration))
                (description "Configure XDG user directories.  To
disable a directory, point it to the $HOME.")))

(define (generate-home-xdg-user-directories-documentation)
  (generate-documentation
   `((home-xdg-user-directories-configuration
     ,home-xdg-user-directories-configuration-fields))
   'home-xdg-user-directories-configuration))


;;;
;;; XDG MIME applications.
;;;

;; Example config
;;
;; (home-xdg-mime-applications-configuration
;;   (added '((x-scheme-handler/magnet . torrent.desktop)))
;;   (default '((inode/directory . file.desktop)))
;;   (removed '((inode/directory . thunar.desktop)))
;;   (desktop-entries
;;    (list (xdg-desktop-entry
;;           (file "file")
;;           (name "File manager")
;;           (type 'application)
;;           (extra-config
;;            '((exec . "emacsclient -c -a emacs %u"))))
;;          (xdg-desktop-entry
;;           (file "text")
;;           (name "Text editor")
;;           (type 'application)
;;           (extra-config
;;            '((exec . "emacsclient -c -a emacs %u")))))))

;; See
;; <https://specifications.freedesktop.org/shared-mime-info-spec/shared-mime-info-spec-latest.html>
;; <https://specifications.freedesktop.org/mime-apps-spec/mime-apps-spec-latest.html>

(define alist? list?)
(define (serialize-alist field-name val)
  (define (serialize-mimelist-entry key val)
    (let ((val (cond
                ((list? val)
                 (string-join (map maybe-object->string val) ";"))
                ((or (string? val) (symbol? val))
                 val)
                (else (raise (formatted-message
                              (G_ "\
The value of an XDG MIME entry must be a list, string or symbol, was given ~a")
                              val))))))
      (format #f "~a=~a\n" key val)))

  (define (merge-duplicates alist acc)
    "Merge values that have the same key.

@example
(merge-duplicates '((key1 . value1)
                      (key2 . value2)
                      (key1 . value3)
                      (key1 . value4)) '())

@result{} ((key1 . (value4 value3 value1)) (key2 . value2))
@end example"
    (cond
     ((null? alist) acc)
     (else (let* ((head (first alist))
                  (tail (cdr alist))
                  (key (first head))
                  (value (cdr head))
                  (duplicate? (assoc key acc)))
             (if duplicate?
                 ;; XXX: This will change the order of things,
                 ;; though, it shouldn't be a problem for XDG MIME.
                 (merge-duplicates
                  tail
                  (alist-cons key
                              (cons value (maybe-list (cdr duplicate?)))
                              (alist-delete key acc)))
                 (merge-duplicates tail (cons head acc)))))))

  (string-append (if (equal? field-name 'default)
                     "\n[Default Applications]\n"
                     (format #f "\n[~a Associations]\n"
                             (string-capitalize (symbol->string field-name))))
                 (generic-serialize-alist string-append
                                          serialize-mimelist-entry
                                          (merge-duplicates val '()))))

(define xdg-desktop-types (make-enumeration
                           '(application
                             link
                             directory)))

(define (xdg-desktop-type? type)
  (unless (enum-set-member? type xdg-desktop-types)
    (raise (formatted-message
            (G_ "XDG desktop type must be of of ~a, was given: ~a")
            (list->human-readable-list (enum-set->list xdg-desktop-types))
            type))))


;; TODO: Add proper docs for this
;; XXX: 'define-configuration' require that fields have a default
;; value.
(define-record-type* <xdg-desktop-entry>
  xdg-desktop-entry make-xdg-desktop-entry
  xdg-desktop-entry?
  ;; ".desktop" will automatically be added
  (file xdg-desktop-entry-file)         ; string
  (name xdg-desktop-entry-name)         ; string
  (type xdg-desktop-entry-type)         ; xdg-desktop-type
  (extra-config xdg-desktop-entry-type-extra-config ; alist
                (default '())))

(define desktop-entries? list?)
(define (serialize-desktop-entries field-name val) "")

(define (serialize-xdg-desktop-entry entry)
  "Return a tuple of the file name for ENTRY and the serialized
configuration."
  (define (format-config key val)
    (let ((val (cond
                ((list? val)
                 (string-join (map maybe-object->string val) ";"))
                ((boolean? val)
                 (if val "true" "false"))
                (else val)))
          (key (string-capitalize (maybe-object->string key))))
      (format #f "~a=~a\n"
              (if (string-suffix? key "?")
                  (string-drop-right key (- (string-length key) 1))
                  key)
              val)))
  
  (match entry
    (($ <xdg-desktop-entry> file name type extra-config)
     (list (if (string-suffix? file ".desktop")
               file
               (string-append file ".desktop"))
           (string-append
            "[Desktop Entry]\n"
            (format #f "Name=~a\n" (string-capitalize name))
            (format #f "Type=~a\n"
                    (string-capitalize (symbol->string type)))
            (generic-serialize-alist string-append
                                     format-config
                                     extra-config))))))

(define-configuration home-xdg-mime-applications-configuration
  (added
   (alist '())
   "An association list of MIME types and desktop entries which indicate
that the application should used to open the specified MIME type.  The
value has to be string, symbol, or list of strings or symbols, this
applies to the `@code{default}', and `@code{removed}' fields as well.")
  (default
    (alist '())
    "An association list of MIME types and desktop entries which indicate
that the application should be the default for opening the specified
MIME type.")
  (removed
   (alist '())
   "An association list of MIME types and desktop entries which indicate
that the application cannot open the specified MIME type.")
  (desktop-entries
   (desktop-entries '())
   "A list of XDG desktop entries to create.  See
@code{xdg-desktop-entry}."))

(define (home-xdg-mime-applications-files-service config)
  (define (add-xdg-desktop-entry-file entry)
    (let ((file (first entry))
          (config (second entry)))
      (list (format #f "local/share/applications/~a" file)
          (mixed-text-file
           (format #f "xdg-desktop-~a-entry" file)
           config))))

  (append
   `(("config/mimeapps.list"
      ,(mixed-text-file
        "xdg-mime-appplications"
        (serialize-configuration
         config
         home-xdg-mime-applications-configuration-fields))))
   (map (compose add-xdg-desktop-entry-file serialize-xdg-desktop-entry)
        (home-xdg-mime-applications-configuration-desktop-entries config))))

(define (home-xdg-mime-applications-extension old-config extension-configs)
  (define (extract-fields config)
    ;; return '(added default removed desktop-entries)
    (list (home-xdg-mime-applications-configuration-added config)
          (home-xdg-mime-applications-configuration-default config)
          (home-xdg-mime-applications-configuration-removed config)
          (home-xdg-mime-applications-configuration-desktop-entries config)))

  (define (append-configs elem acc)
    (list (append (first elem) (first acc))
          (append (second elem) (second acc))
          (append (third elem) (third acc))
          (append (fourth elem) (fourth acc))))

  ;; TODO: Implement procedure to check for duplicates without
  ;; sacrificing performance.
  ;;
  ;; Combine all the alists from 'added', 'default' and 'removed'
  ;; into one big alist.
  (let ((folded-configs (fold append-configs
                              (extract-fields old-config)
                              (map extract-fields extension-configs))))
    (home-xdg-mime-applications-configuration
     (added (first folded-configs))
     (default (second folded-configs))
     (removed (third folded-configs))
     (desktop-entries (fourth folded-configs)))))

(define home-xdg-mime-applications-service-type
  (service-type (name 'home-xdg-mime-applications)
                (extensions
                 (list (service-extension
                        home-files-service-type
                        home-xdg-mime-applications-files-service)))
                (compose identity)
                (extend home-xdg-mime-applications-extension)
                (default-value (home-xdg-mime-applications-configuration))
                (description "\
Configure XDG MIME applications, and XDG desktop entries.")))
