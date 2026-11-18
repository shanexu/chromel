;;; gui-input.el --- gi focuses the first, second and framed text field -*- lexical-binding: t; -*-
(require 'chromel)
(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))
(defvar chromel-test--buffer nil)
(defvar chromel-test--origin nil)
(defconst chromel-test--active-script
  "(function () {
  let active = document.activeElement;
  while (active && active.tagName === 'IFRAME') {
    try { active = active.contentDocument.activeElement; } catch (error) { break; }
  }
  return JSON.stringify(active ? (active.id || active.tagName) : '');
})()")
(defun chromel-test--assert (value text) (unless value (error "%s" text)))
(defun chromel-test--finish (ok text)
  (with-temp-file (getenv "CHROMEL_TEST_RESULT") (insert (if ok "PASS: " "FAIL: ") text "\n"))
  (kill-emacs (if ok 0 1)))
(defun chromel-test--until (predicate text seconds)
  (let ((deadline (+ (float-time) seconds)) done)
    (while (and (not done) (< (float-time) deadline))
      (setq done (funcall predicate))
      (unless done (accept-process-output nil 0.01)))
    (chromel-test--assert done (format "%s; active=%S title=%S" text
                                       (ignore-errors (chromel--eval chromel-test--active-script))
                                       (and (buffer-live-p chromel-test--buffer)
                                            (buffer-local-value 'chromel--title chromel-test--buffer))))))
(defun chromel-test--title-p (expected)
  (lambda ()
    (and (buffer-live-p chromel-test--buffer)
         (equal (buffer-local-value 'chromel--title chromel-test--buffer) expected))))
(defun chromel-test--active-p (expected)
  (lambda ()
    (and (buffer-live-p chromel-test--buffer)
         (with-current-buffer chromel-test--buffer
           (equal (ignore-errors (chromel--eval chromel-test--active-script)) expected)))))
(defun chromel-test--focus (count expected)
  (with-current-buffer chromel-test--buffer
    (chromel-focus-input count))
  (chromel-test--until (chromel-test--active-p expected)
                       (format "gi %d did not focus %s" (or count 1) expected)
                       10))
(defun chromel-test--run ()
  (condition-case error
      (let ((chromel-focus-on-open nil))
        (setq chromel-test--origin (string-remove-suffix "/inputs" (getenv "CHROMEL_TEST_URL")))
        (setq chromel-test--buffer (chromel (concat chromel-test--origin "/inputs")))
        (chromel-test--until (chromel-test--title-p "inputs-fixture")
                             "The input fixture did not load" 25)
        ;; The hidden and checkbox inputs must be skipped; the count is 1-based.
        (chromel-test--focus nil "first")
        (chromel-test--focus 2 "second")
        (chromel-test--focus 3 "third")
        ;; The fourth field lives in a same-origin frame.
        (chromel-test--focus 4 "fourth")
        (with-current-buffer chromel-test--buffer
          (chromel-test--assert
           (condition-case nil (progn (chromel-focus-input 9) nil) (user-error t))
           "gi 9 should have signalled that there is no ninth field"))
        (chromel-test--finish t "gi walked the text fields, including a framed one"))
    (error (chromel-test--finish nil (error-message-string error)))))
(run-at-time 1 nil #'chromel-test--run)
