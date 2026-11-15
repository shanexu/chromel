;;; gui-paste.el --- Cmd+V and Cmd+C reach the focused page  -*- lexical-binding: t; -*-

;; Cmd+V used to do nothing inside a page: Chromium's own accelerator handling
;; does not run for keys forwarded while Emacs is the active app, so the browser
;; never saw an edit command.  Chromel now drives Paste/Copy/Cut/SelectAll/Undo
;; itself, but only for the page that owns the keyboard.
;;
;; Shape of this test, learned the hard way:
;;  - One timer per step with fixed delays.  A `sit-for' or a polling loop
;;    inside a timer callback keeps Emacs from servicing the timer that drives
;;    the browser, so the script hangs instead of failing.
;;  - The result goes to the CHROMEL_TEST_RESULT file, like the other GUI
;;    scripts; `kill-emacs' given a message string hangs once CEF is running.
;;  - The fixture mirrors the field into `document.title', so the value arrives
;;    through ordinary title events instead of an `eval' (which can block right
;;    after a paste).
;;  - The unfocused half of the rule cannot be asserted here: sending a Command
;;    key through `sendEvent:' while Lisp is still running re-enters the command
;;    loop, so the test would measure its own reentrancy.

(require 'chromel)

(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))

(defvar chromel-test--phase 'loading)
(defconst chromel-test--clipboard "SEED")
(defvar chromel-test--buffer nil)

(defun chromel-test--finish (success description)
  (with-temp-file (getenv "CHROMEL_TEST_RESULT")
    (insert (if success "PASS: " "FAIL: ") description "\n"))
  (kill-emacs (if success 0 1)))

(defun chromel-test--assert (value format-string &rest arguments)
  (unless value
    (chromel-test--finish nil (apply #'format format-string arguments))))

(defun chromel-test--title ()
  (and (buffer-live-p chromel-test--buffer)
       (buffer-local-value 'chromel--title chromel-test--buffer)))

(defun chromel-test--command (name &optional argument)
  (with-current-buffer chromel-test--buffer
    (if argument (chromel--command name argument) (chromel--command name))))

(defun chromel-test--check (title what next)
  (chromel-test--assert (equal (chromel-test--title) title)
                        "%s: wanted %S, got %S" what title (chromel-test--title))
  (run-at-time 0.5 nil next))

(defun chromel-test--run ()
  ;; A clipboard no other process is writing, with known contents.
  (gui-set-selection 'CLIPBOARD chromel-test--clipboard)
  (setq chromel-test--buffer (chromel (getenv "CHROMEL_TEST_URL"))))

(defun chromel-test--step-load ()
  (setq chromel-test--phase 'load)
  (chromel-test--check "value:" "The paste fixture did not load" nil))

(defun chromel-test--step-click ()
  (setq chromel-test--phase 'paste)
  (chromel-test--command "click" (chromel--json (list :x 50 :y 50 :newBuffer :false))))

(defun chromel-test--step-focus ()
  (chromel-test--command "focus"))

(defun chromel-test--step-paste ()
  (chromel-test--command "test-key" "cmd-v"))

(defun chromel-test--step-pasted ()
  (chromel-test--check "value:SEED" "Cmd+V did not paste the clipboard into the page"
                       nil))

(defun chromel-test--step-type-a () (chromel-test--command "test-key" "a"))
(defun chromel-test--step-type-b () (chromel-test--command "test-key" "b"))
(defun chromel-test--step-type-c () (chromel-test--command "test-key" "c"))

(defun chromel-test--step-typed ()
  (chromel-test--check "value:SEEDabc" "Typing did not reach the field"
                       nil))

(defun chromel-test--step-select-all ()
  (setq chromel-test--phase 'copy)
  (chromel-test--command "test-key" "cmd-a"))

(defun chromel-test--step-copy ()
  (chromel-test--command "test-key" "cmd-c"))

(defun chromel-test--step-type-z () (chromel-test--command "test-key" "z"))

(defun chromel-test--step-replaced ()
  (chromel-test--check "value:z" "Cmd+A did not select the whole field"
                       nil))

(defun chromel-test--step-paste-again ()
  (chromel-test--command "test-key" "cmd-v"))

(defun chromel-test--step-finish ()
  ;; "SEED" came from us; "zSEEDabc" can only come back if Cmd+C copied it.
  (chromel-test--assert (equal (chromel-test--title) "value:zSEEDabc")
                        "Cmd+C did not copy the field: %S" (chromel-test--title))
  (setq chromel-test--phase 'done)
  (chromel-test--finish t "Cmd+V pastes into the focused page and Cmd+A/C copies out of it"))

(run-at-time 1 nil #'chromel-test--run)
(run-at-time 4 nil #'chromel-test--step-load)
(run-at-time 4.5 nil #'chromel-test--step-click)
(run-at-time 5.5 nil #'chromel-test--step-focus)
(run-at-time 6.5 nil #'chromel-test--step-paste)
(run-at-time 7.5 nil #'chromel-test--step-pasted)
(run-at-time 8 nil #'chromel-test--step-type-a)
(run-at-time 8.3 nil #'chromel-test--step-type-b)
(run-at-time 8.6 nil #'chromel-test--step-type-c)
(run-at-time 9.6 nil #'chromel-test--step-typed)
(run-at-time 10.1 nil #'chromel-test--step-select-all)
(run-at-time 10.4 nil #'chromel-test--step-copy)
(run-at-time 10.7 nil #'chromel-test--step-type-z)
(run-at-time 11.7 nil #'chromel-test--step-replaced)
(run-at-time 12.2 nil #'chromel-test--step-paste-again)
(run-at-time 13.2 nil #'chromel-test--step-finish)
