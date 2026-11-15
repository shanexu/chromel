;;; gui-proxy.el --- A PAC file must actually route the requests -*- lexical-binding: t; -*-
;; Chromium reads the PAC when the browser process starts, so the file has to be
;; in place before the first (chromel ...) call.  The rule below sends one
;; hostname to a dead proxy and everything else direct: if the PAC is ignored,
;; both pages load and the first assertion fails.
(require 'chromel)
(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))
(setq chromel-proxy-pac-file (make-temp-file "chromel-pac" nil ".pac"))
(with-temp-file chromel-proxy-pac-file
  (insert "function FindProxyForURL(url, host) {\n"
          "  if (host === \"chromel-proxy.invalid\") return \"PROXY 127.0.0.1:9\";\n"
          "  return \"DIRECT\";\n"
          "}\n"))
(defvar chromel-test--buffer nil)
(defvar chromel-test--url (getenv "CHROMEL_TEST_URL"))
(defun chromel-test--assert (value text) (unless value (error "%s" text)))
(defun chromel-test--finish (ok text)
  (with-temp-file (getenv "CHROMEL_TEST_RESULT")
    (insert (if ok "PASS: " "FAIL: ") text "\n"))
  (kill-emacs (if ok 0 1)))
(defun chromel-test--title (&optional buffer)
  (buffer-local-value 'chromel--title (or buffer chromel-test--buffer)))
(defun chromel-test--until (predicate text seconds)
  (let ((deadline (+ (float-time) seconds)) done)
    (while (and (not done) (< (float-time) deadline))
      (setq done (funcall predicate))
      (unless done (accept-process-output nil 0.01)))
    (chromel-test--assert done (format "%s; title=%S" text (chromel-test--title)))))
(defun chromel-test--run ()
  (condition-case error
      (progn
        ;; The fixture host is not in the PAC, so this must still load directly.
        (setq chromel-test--buffer (chromel chromel-test--url))
        (chromel-test--until (lambda () (equal (chromel-test--title) "chromel-emacs-restored"))
                             "The direct page never loaded" 20)
        ;; This host is routed to a dead proxy, so Chromium must show its error
        ;; page; the readable title of that page is the hostname itself.
        (let ((blocked (chromel "http://chromel-proxy.invalid/")))
          (chromel-test--until
           (lambda () (equal (chromel-test--title blocked) "chromel-proxy.invalid"))
           "The PAC was ignored: the blocked host rendered" 20))
        (with-current-buffer chromel-test--buffer (chromel--select-buffer chromel-test--buffer))
        (sit-for 0.5)
        (chromel-test--finish t "the PAC routed one host and passed the rest through"))
    (error (chromel-test--finish nil (error-message-string error)))))

(run-at-time 1 nil #'chromel-test--run)
