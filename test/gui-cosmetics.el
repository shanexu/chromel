;;; gui-cosmetics.el --- Hidden ads stay hidden, in every frame -*- lexical-binding: t; -*-
(require 'chromel)
(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))
(defvar chromel-test--buffer nil)
(defvar chromel-test--origin nil)
(defun chromel-test--assert (value text) (unless value (error "%s" text)))
(defun chromel-test--finish (ok text)
  (with-temp-file (getenv "CHROMEL_TEST_RESULT") (insert (if ok "PASS: " "FAIL: ") text "\n"))
  (kill-emacs (if ok 0 1)))
(defun chromel-test--until (predicate text seconds)
  (let ((deadline (+ (float-time) seconds)) done)
    (while (and (not done) (< (float-time) deadline))
      (setq done (funcall predicate))
      (unless done (accept-process-output nil 0.01)))
    (chromel-test--assert done (format "%s; title=%S cosmetics=%S"
                                       text
                                       (and (buffer-live-p chromel-test--buffer)
                                            (buffer-local-value 'chromel--title chromel-test--buffer))
                                       (and (fboundp 'chromel--native-cosmetics-info)
                                            (chromel--native-cosmetics-info))))))
(defun chromel-test--title-p (expected)
  (lambda ()
    (and (buffer-live-p chromel-test--buffer)
         (equal (buffer-local-value 'chromel--title chromel-test--buffer) expected))))
(defun chromel-test--run ()
  (condition-case error
      (let* ((directory (make-temp-file "chromel-cosmetics" t))
             (file (expand-file-name "cosmetics.txt" directory)))
        ;; One generic rule and one per-host rule.  The iframe loads from the
        ;; same host, so the host rule has to apply there too.
        (with-temp-file file
          (insert "g\t.ad-generic\n"
                  "h\t127.0.0.1\t#banner\n"))
        (setq chromel-cosmetics-file file)
        (setq chromel-test--origin (string-remove-suffix "/cosmetic" (getenv "CHROMEL_TEST_URL")))
        (setq chromel-test--buffer (chromel (concat chromel-test--origin "/cosmetic")))
        (chromel-test--until (chromel-test--title-p "cosmetic:true:true:true")
                             "The ads were not hidden in both frames" 25)
        ;; injected counts frames: the main document and the iframe.
        (let ((info (chromel--native-cosmetics-info)))
          (chromel-test--assert (string-match-p "hosts=1 " info)
                                (format "The one-host snapshot was not live: %s" info))
          (chromel-test--assert (string-match-p "injected=[2-9]" info)
                                (format "Both frames should have been styled: %s" info)))
        (delete-directory directory t)
        (chromel-test--finish t "generic and per-host rules hide elements in every frame"))
    (error (chromel-test--finish nil (error-message-string error)))))
(run-at-time 1 nil #'chromel-test--run)
