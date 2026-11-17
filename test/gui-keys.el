;;; gui-keys.el --- Emacs prefixes survive a focused page -*- lexical-binding: t; -*-
;; A focused page hands Control keys it does not own back to Emacs.  Without
;; this, C-x, C-c and C-h would be swallowed by Chromium and the user would
;; have to unfocus the page before every Emacs command.
(require 'chromel)
(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))
(defvar chromel-test--buffer nil)
(defvar chromel-test--deadline (+ (float-time) 60))
(defun chromel-test--assert (value message) (unless value (error "%s" message)))
(defun chromel-test--finish (ok text)
  (with-temp-file (getenv "CHROMEL_TEST_RESULT") (insert (if ok "PASS: " "FAIL: ") text "\n"))
  (kill-emacs (if ok 0 1)))
(defun chromel-test--read (first second)
  "Focus the page, press FIRST then SECOND, and return what Emacs read."
  (let* ((buffer chromel-test--buffer)
         (expected (kbd (concat first " " second)))
         (map (make-sparse-keymap))
         ;; "C-x" -> "ctrl-x": the harness speaks key names, not Emacs syntax.
         (first-key (concat "ctrl-" (downcase (substring first 2))))
         (second-key (concat "ctrl-" (downcase (substring second 2))))
         (inject-first nil)
         (inject-second nil))
    (with-current-buffer buffer
      (use-local-map map)
      (define-key map expected #'ignore)
      (chromel-focus))
    (unwind-protect
        (progn
          (setq inject-first
                (run-at-time 0.1 nil
                             (lambda ()
                               (with-current-buffer buffer
                                 (chromel--command "test-key" first-key)))))
          ;; read-key-sequence is already waiting for the rest of the prefix.
          (setq inject-second
                (run-at-time 0.4 nil
                             (lambda ()
                               (with-current-buffer buffer
                                 (chromel--command "test-key" second-key)))))
          (let ((bail (run-at-time 5 nil (lambda () (setq unread-command-events (list ?z))))))
            (unwind-protect
                (read-key-sequence (format "Test %s %s" first second))
              (cancel-timer bail))))
      (when (timerp inject-first) (cancel-timer inject-first))
      (when (timerp inject-second) (cancel-timer inject-second))
      (with-current-buffer buffer (use-local-map nil)))))
(defun chromel-test--exercise ()
  (interactive)
  (condition-case error
      (with-current-buffer chromel-test--buffer
        (when (> (float-time) chromel-test--deadline) (error "Key prefix test timed out"))
        (switch-to-buffer chromel-test--buffer)
        (delete-other-windows)
        (chromel--sync)
        ;; The page must stay focused for the whole check: that is the state
        ;; the prefixes used to break in.
        (dolist (pair '(("C-x" "C-h") ("C-c" "C-h") ("C-h" "C-h")))
          (let ((got (chromel-test--read (nth 0 pair) (nth 1 pair)))
                (want (kbd (concat (nth 0 pair) " " (nth 1 pair)))))
            (chromel-test--assert (equal got want)
                                  (format "%s did not reach Emacs: got %S, wanted %S"
                                          (nth 0 pair) got want))))
        (kill-buffer chromel-test--buffer)
        (let ((deadline (+ (float-time) 3)))
          (while (and (< (float-time) deadline)
                      (not (string-match-p "Browsers including DevTools: 0" (chromel--native-info))))
            (chromel--tick)
            (accept-process-output nil 0.02)))
        (chromel-test--finish t "C-x, C-c and C-h reach Emacs while a page is focused"))
    (error (chromel-test--finish nil (error-message-string error)))))
(defun chromel-test--start ()
  (condition-case error
      (let ((buffer (chromel (getenv "CHROMEL_TEST_URL"))))
        (setq chromel-test--buffer buffer)
        (with-current-buffer buffer
          (let ((deadline (+ (float-time) 25)) title)
            (while (and (not (equal title "chromel-emacs-restored"))
                        (< (float-time) deadline))
              (setq title chromel--title)
              (unless (equal title "chromel-emacs-restored")
                (accept-process-output nil 0.01)))
            (chromel-test--assert (equal title "chromel-emacs-restored")
                                  (format "The page never loaded: title=%S" title))))
        (run-at-time 0.2 nil #'chromel-test--exercise))
    (error (chromel-test--finish nil (error-message-string error)))))
(run-at-time 1 nil #'chromel-test--start)
