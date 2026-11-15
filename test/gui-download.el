;;; gui-download.el --- Downloads land in the configured directory -*- lexical-binding: t; -*-
(require 'chromel)
(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))
(defvar chromel-test--buffer nil)
(defvar chromel-test--downloads
  (expand-file-name "downloads" (file-name-directory (directory-file-name chromel-data-directory))))
(setq chromel-download-directory chromel-test--downloads)
(defun chromel-test--assert (value text) (unless value (error "%s" text)))
(defun chromel-test--finish (ok text)
  (with-temp-file (getenv "CHROMEL_TEST_RESULT") (insert (if ok "PASS: " "FAIL: ") text "\n"))
  (kill-emacs (if ok 0 1)))
(defun chromel-test--until (predicate text seconds)
  (let ((deadline (+ (float-time) seconds)) done)
    (while (and (not done) (< (float-time) deadline))
      (setq done (funcall predicate))
      (unless done (accept-process-output nil 0.01)))
    (chromel-test--assert done (format "%s; dir=%S files=%S" text chromel-test--downloads
                                       (and (file-directory-p chromel-test--downloads)
                                            (directory-files chromel-test--downloads nil "\\`[^.]"))))))
(defun chromel-test--file (name)
  (expand-file-name name chromel-test--downloads))
(defun chromel-test--fetch (url)
  (with-current-buffer chromel-test--buffer
    (chromel--command "javascript" (format "location.href='%s'" url))))
(defun chromel-test--loaded-p ()
  (with-current-buffer chromel-test--buffer
    (equal chromel--status "")))
(defun chromel-test--origin ()
  "Scheme, host and port of the fixture server."
  (string-remove-suffix "/fixture" (getenv "CHROMEL_TEST_URL")))
(defun chromel-test--run ()
  (condition-case error
      (progn
        (setq chromel-test--buffer (chromel (getenv "CHROMEL_TEST_URL")))
        (with-current-buffer chromel-test--buffer (chromel--command "reload"))
        (chromel-test--until
         (lambda ()
           (with-current-buffer chromel-test--buffer
             (equal chromel--title "chromel-emacs-restored")))
         "The fixture never loaded" 20)
        (let ((first (chromel-test--file "chromel-fixture.txt")))
          (chromel-test--fetch "/download")
          (chromel-test--until (lambda () (file-exists-p first))
                               "The download never appeared" 20)
          (with-temp-buffer
            (insert-file-contents first)
            (chromel-test--assert (equal (buffer-string) "chromel download fixture\n")
                                  (format "Wrong contents: %S" (buffer-string))))
          ;; Chromium allows one automatic download per page, and a page that
          ;; just handed one to the download manager stops running scripts, so
          ;; the second copy comes from a fresh tab and a real click.  A trusted
          ;; gesture is also what the browser wants before it repeats itself.
          (let ((second (chromel (concat (chromel-test--origin) "/again.html"))))
            (chromel-test--until
             (lambda ()
               (and (buffer-live-p second)
                    (buffer-local-value 'chromel--title second)
                    (equal (buffer-local-value 'chromel--title second) "again-fixture")))
             "The again fixture did not load" 20)
            (with-current-buffer second
              (chromel--command
               "click" (chromel--json (list :x 40 :y 30 :newBuffer :false))))
            (chromel-test--until
             (lambda () (file-exists-p (chromel-test--file "chromel-fixture (1).txt")))
             "A second download did not get a unique name" 20)))
        (chromel-test--finish t "downloads saved with unique names"))
    (error (chromel-test--finish nil (error-message-string error)))))
(run-at-time 1 nil #'chromel-test--run)
