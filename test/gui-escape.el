;;; gui-escape.el --- Real Escape routing regression -*- lexical-binding: t; -*-
(require 'chromel)
(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))
(setq ns-use-native-fullscreen nil)
(when (getenv "CHROMEL_TEST_FULLSCREEN")
  (set-frame-parameter nil 'fullscreen 'fullboth))
(defvar chromel-test--buffer nil)
(defvar chromel-test--busy nil)
(defvar chromel-test--deadline (+ (float-time) 35))
(defun chromel-test--assert (value message) (unless value (error "%s" message)))
(defun chromel-test--finish (ok text)
  (with-temp-file (getenv "CHROMEL_TEST_RESULT") (insert (if ok "PASS: " "FAIL: ") text "\n"))
  (kill-emacs (if ok 0 1)))
(defun chromel-test--escape ()
  ;; Feed an actual Cocoa key while Emacs is reading input.  Accept either
  ;; immediate quit or a Control-g key sequence, as normal C-g can do both.
  (let* ((buffer chromel-test--buffer)
         ;; A posted key event is dropped when macOS has not yet made the
         ;; disposable window key, which depends on whatever the user clicked
         ;; last.  Keep offering the key until one arrives; a broken
         ;; translation still fails, because Escape would then reach Emacs as
         ;; a prefix key instead of C-g.
         (inject (run-at-time 0.1 0.25 (lambda () (with-current-buffer buffer (chromel--command "test-key" "escape")))))
         (timeout (run-at-time 5 nil (lambda () (setq unread-command-events (list ?z)))))
         (key (unwind-protect
                  (condition-case nil (read-key-sequence "Test Escape") (quit 'quit))
                (cancel-timer inject) (cancel-timer timeout))))
    (chromel-test--assert (or (eq key 'quit) (equal key (kbd "C-g")))
                      (format "Escape did not become C-g: %S; %s; fullscreen=%S" key (chromel--native-inspect chromel--id) (frame-parameter nil 'fullscreen)))))
(defun chromel-test--exercise ()
  (interactive)
  (condition-case err
      (with-current-buffer chromel-test--buffer
        (when (> (float-time) chromel-test--deadline) (error "Escape test timed out"))
        (progn
          (switch-to-buffer chromel-test--buffer)
          (delete-other-windows)
          (chromel--sync)
          (chromel--eval "JSON.stringify((window.escapeCount=0,addEventListener('keydown',e=>{if(e.key==='Escape')escapeCount++}),document.querySelector('input').focus(),true))")
          (chromel-focus)
          (message "Testing page Escape")
          (chromel-test--escape)
          (chromel-test--assert (eq :false (plist-get (json-parse-string (chromel--native-inspect chromel--id) :object-type 'plist) :focused)) "Escape left focus in the page")
          (chromel-test--assert (= 0 (chromel--eval "JSON.stringify(escapeCount)")) "Escape leaked to the page")
          ;; Now Emacs owns the keyboard: Meow must not override C-g.
          (message "Testing command Escape")
          (when (fboundp 'meow-normal-mode) (meow-normal-mode 1))
          (chromel-test--escape)
          (when (getenv "CHROMEL_TEST_FULLSCREEN")
            (chromel-test--assert (eq (frame-parameter nil 'fullscreen) 'fullboth)
                              "Escape exited fullscreen"))
          (kill-buffer chromel-test--buffer)
          (let ((deadline (+ (float-time) 3)))
            (while (and (< (float-time) deadline) (not (string-match-p "Browsers including DevTools: 0" (chromel--native-info))))
              (chromel--tick) (accept-process-output nil 0.02)))
          (chromel-test--finish t "Cocoa Escape becomes C-g in focused input and Emacs/Meow; no page Escape; fullscreen preserved")))
    (error (chromel-test--finish nil (error-message-string err)))))
(global-set-key [chromel-test-run] #'chromel-test--exercise)
(defun chromel-test--step ()
  (unless chromel-test--busy
    (when (with-current-buffer chromel-test--buffer
            (equal chromel--title (getenv "CHROMEL_TEST_EXPECT_TITLE")))
      (setq chromel-test--busy t
            unread-command-events (list 'chromel-test-run)))))

(run-at-time 1 nil (lambda ()
                     (setq chromel-test--buffer (chromel (getenv "CHROMEL_TEST_URL")))
                     (run-at-time 0.2 0.2 #'chromel-test--step)))
