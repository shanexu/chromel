;;; gui-crash.el --- A dead renderer must leave an actionable page -*- lexical-binding: t; -*-
;; chrome://crash is a Chrome-layer URL that CEF does not serve, so the only
;; honest way to test the handler is to kill the renderer ourselves.
(require 'chromel)
(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))
(defvar chromel-test--buffer nil)
(defvar chromel-test--url (getenv "CHROMEL_TEST_URL"))
(defun chromel-test--assert (value text) (unless value (error "%s" text)))
(defun chromel-test--finish (ok text)
  (with-temp-file (getenv "CHROMEL_TEST_RESULT") (insert (if ok "PASS: " "FAIL: ") text "\n"))
  (kill-emacs (if ok 0 1)))
(defun chromel-test--url-now () (buffer-local-value 'chromel--url chromel-test--buffer))
(defun chromel-test--until (predicate text seconds)
  (let ((deadline (+ (float-time) seconds)) done)
    (while (and (not done) (< (float-time) deadline))
      (setq done (funcall predicate))
      (unless done (accept-process-output nil 0.01)))
    (chromel-test--assert done (format "%s; url=%s crashed=%S" text (chromel-test--url-now)
                                       (buffer-local-value 'chromel--crashed chromel-test--buffer)))))
(defun chromel-test--loaded-p () (string-suffix-p "/crash.html" (or (chromel-test--url-now) "")))
(defun chromel-test--crash-renderer ()
  "SIGKILL the renderer processes this Emacs started; return how many."
  (let* ((cmd (format "ps -ax -o pid=,ppid=,args= | awk -v p=%d '$2==p' | grep -e '--type=renderer' | awk '{print $1}'"
                      (emacs-pid)))
         (pids (split-string (shell-command-to-string cmd))))
    (chromel-test--assert pids "Could not find a renderer process to kill")
    (dolist (pid pids) (call-process "kill" nil nil nil "-9" pid))
    (length pids)))
(defun chromel-test--run ()
  (condition-case error
      (progn
        (setq chromel-test--buffer (chromel chromel-test--url))
        (with-current-buffer chromel-test--buffer (chromel--command "reload"))
        (chromel-test--until #'chromel-test--loaded-p "The fixture never loaded" 20)
        (let ((killed (chromel-test--crash-renderer)))
          (chromel-test--until
           (lambda () (buffer-local-value 'chromel--crashed chromel-test--buffer))
           (format "No crash was reported after killing %d renderer(s)" killed) 20))
        ;; The navigation to the data: page is another round trip through CEF.
        (chromel-test--until
         (lambda () (string-prefix-p "data:text/html" (or (chromel-test--url-now) "")))
         "No crash page was shown" 15)
        (chromel-test--assert (string-match-p "reload" (url-unhex-string (chromel-test--url-now)))
                              "The crash page does not tell the user what to do")
        (with-current-buffer chromel-test--buffer (chromel-reload))
        (chromel-test--until #'chromel-test--loaded-p "Reload did not leave the crash page" 20)
        (with-current-buffer chromel-test--buffer
          (chromel-test--assert (not chromel--crashed) "The crash flag survived a reload"))
        ;; Give the idle history timer a chance: the runner checks history.json.
        (sit-for 2)
        (chromel-test--finish t "renderer crash shows a retry page, reload recovers"))
    (error (chromel-test--finish nil (error-message-string error)))))
(run-at-time 1 nil #'chromel-test--run)
