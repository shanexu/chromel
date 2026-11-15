;;; gui-hints.el --- Link hints in a real renderer -*- lexical-binding: t; -*-
(require 'chromel)
(require 'cl-lib)
(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))
(defvar chromel-test--source nil)
(defvar chromel-test--child nil)
(defvar chromel-test--phase 'loading)
(defvar chromel-test--deadline (+ (float-time) 35))
(defvar chromel-test--busy nil)

(defun chromel-test--follow-link-to (suffix command)
  "Pick the hint whose URL ends with SUFFIX and run COMMAND.

The overlay labels only the entries that fit the viewport, so a shorter window
yields fewer (and differently labelled) hints.  Choosing by URL keeps this test
independent of how many links happen to be visible."
  (cl-letf (((symbol-function 'chromel--read-hint)
             (lambda (hints session)
               (let ((entry (seq-find (lambda (hint)
                                        (let ((url (plist-get hint :url)))
                                          (and (stringp url) (string-suffix-p suffix url))))
                                      hints)))
                 (unless entry (error "No hint for %s among %S" suffix hints))
                 (chromel--hint-call session "filter" (plist-get entry :label))
                 (list :label (plist-get entry :label))))))
    (funcall command)))

(defun chromel-test--assert (value description)
  (unless value (error "%s" description)))

(defun chromel-test--trace (description)
  (write-region (concat description "\n") nil (getenv "CHROMEL_TEST_RESULT") t 'silent))

(defun chromel-test--finish (success description)
  (let ((trace (when (file-exists-p (getenv "CHROMEL_TEST_RESULT"))
                 (with-temp-buffer (insert-file-contents (getenv "CHROMEL_TEST_RESULT")) (buffer-string)))))
    (with-temp-file (getenv "CHROMEL_TEST_RESULT")
      (insert (or trace "") (if success "PASS: " "FAIL: ") description "\n")))
  (kill-emacs (if success 0 1)))

(defun chromel-test--overlay-count ()
  (chromel--eval "JSON.stringify(document.querySelectorAll('[data-emacs-chromel-hints]').length)"))

(defun chromel-test--step ()
 (unless chromel-test--busy
  (let ((chromel-test--busy t))
   (with-current-buffer (window-buffer (selected-window))
  (condition-case err
      (progn
        (when (> (float-time) chromel-test--deadline) (error "Hints timed out: %s" chromel-test--phase))
        (pcase chromel-test--phase
          ('loading
           (when (equal (buffer-local-value 'chromel--title chromel-test--source)
                        (getenv "CHROMEL_TEST_EXPECT_TITLE"))
             (switch-to-buffer chromel-test--source)
             (delete-other-windows)
             (chromel--sync)
             (chromel--command "unfocus")
             (chromel-test--trace "Inspecting badges")
             (let ((hints (chromel--eval (format "%s(\"as\",\"inspect\")" (chromel--hint-script)))))
               (chromel-test--assert (= 6 (length hints))
                                 (format "Hidden/covered/offscreen link filtering failed: %S" hints))
               (chromel-test--assert (= 3 (length (plist-get (car hints) :label))) "Expected multiletter labels")
               (chromel-test--assert (= 1 (chromel-test--overlay-count)) "Hint badges were not attached")
               (chromel--eval (chromel--hint-call "inspect" "filter" "s"))
               (chromel-test--assert
                (= 2 (chromel--eval "JSON.stringify(Array.from(document.querySelector('[data-emacs-chromel-hints]').shadowRoot.children).filter(x=>!x.hidden).length)"))
                "Prefix filtering did not hide unmatched badges")
               (chromel--eval (chromel--hint-call "inspect" "clear")))
             (chromel-test--trace "Cancelling hints")
             ;; Drive the real command's cancellation path.
             (let ((unread-command-events '(7)))
               (condition-case nil (chromel-follow) (quit nil)))
             (chromel-test--assert (= 0 (chromel-test--overlay-count)) "Cancel left hint badges behind")
             (chromel-test--trace "Opening new buffer by label")
             ;; A completed label opens a new buffer without Return.
             (chromel-test--follow-link-to "/hint-target" #'chromel-follow-new-buffer)
             (setq chromel-test--phase 'opening)))
          ('opening
           (when (not (eq (window-buffer (selected-window)) chromel-test--source))
             (setq chromel-test--child (window-buffer (selected-window)))
             (chromel-test--assert (not (eq chromel-test--child chromel-test--source)) "New-buffer follow reused source")
             (chromel-test--assert (equal (buffer-local-value 'chromel--url chromel-test--source) (getenv "CHROMEL_TEST_URL"))
                               "New-buffer follow navigated the source")
             (setq chromel-test--phase 'child)))
          ('child
           (when (equal (buffer-local-value 'chromel--title chromel-test--child) "hint-target")
             (chromel-test--assert
              (eq :false (plist-get (json-parse-string (chromel--native-inspect chromel--id) :object-type 'plist) :focused))
              "New-buffer hint lost Emacs command focus")
             (chromel-test--trace "Following in current buffer")
             (kill-buffer chromel-test--child)
             (switch-to-buffer chromel-test--source)
             (chromel--sync)
             (chromel-test--assert (= 0 (chromel-test--overlay-count)) "New-buffer follow left badges behind")
             (chromel-test--follow-link-to "/hint-target" #'chromel-follow)
             (chromel-test--assert (eq (window-buffer (selected-window)) chromel-test--source) "Current-page follow made a buffer")
             (setq chromel-test--phase 'followed)))
          ('followed
           (when (equal (buffer-local-value 'chromel--title chromel-test--source) "hint-target")
             (chromel-test--assert
              (eq :false (plist-get (json-parse-string (chromel--native-inspect chromel--id) :object-type 'plist) :focused))
              "Navigation after hint lost Emacs command focus")
             (chromel-test--assert (= 0 (chromel-test--overlay-count)) "Navigation left badges behind")
             (let (empty)
               (condition-case nil (chromel-follow) (user-error (setq empty t)))
               (chromel-test--assert empty "Empty page did not report no visible links"))
             (chromel-test--assert (= 0 (chromel-test--overlay-count)) "Empty page left badges behind")
             (kill-buffer chromel-test--source)
             (setq chromel-test--phase 'closing)))
          ('closing
           (when (string-match-p "Browsers including DevTools: 0" (chromel--native-info))
             (chromel-test--finish t "Link hints: visibility, shadow DOM, multiletter labels, filtering, cancel, current/new buffer, cleanup")))))
    (error (chromel-test--finish nil (format "%s (phase %s, buffer %s, selected %s)"
                                        (error-message-string err) chromel-test--phase
                                        (buffer-name) (buffer-name (window-buffer (selected-window)))))))))))

(run-at-time 1 nil
             (lambda ()
               (condition-case err
                   (progn
                     (setq chromel-test--source (chromel (getenv "CHROMEL_TEST_URL")))
                     (run-at-time 0.2 0.2 #'chromel-test--step))
                 (error (chromel-test--finish nil (error-message-string err))))))
