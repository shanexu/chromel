;;; chromel-test.el --- Regression tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'chromel)

(ert-deftest chromel-data-directory-preserves-legacy-profile ()
  (let* ((user-emacs-directory (make-temp-file "chromel-data-test-" t))
         (legacy (expand-file-name "web/" user-emacs-directory))
         (current (expand-file-name "chromel/" user-emacs-directory)))
    (unwind-protect
        (progn
          (should (equal (chromel--default-data-directory) current))
          (make-directory legacy)
          (with-temp-file (expand-file-name "session.json" legacy) (insert "saved"))
          (should (equal (chromel--default-data-directory) legacy))
          (should-not (file-exists-p current))
          (make-directory current)
          (should (equal (chromel--default-data-directory) current))
          (should (equal (with-temp-buffer
                           (insert-file-contents (expand-file-name "session.json" legacy))
                           (buffer-string))
                         "saved")))
      (delete-directory user-emacs-directory t))))

(ert-deftest chromel-hints-prefix-backspace-and-invalid-input ()
  (let ((keys '(?a 127 ?z ?s ?a)) prefixes)
    (cl-letf (((symbol-function 'read-key) (lambda (&rest _) (pop keys)))
              ((symbol-function 'chromel--eval) (lambda (script) (push script prefixes) t)))
      (should (equal (plist-get
                      (chromel--read-hint '((:label "aa" :url "https://a.example")
                                        (:label "sa" :url "https://b.example")) "test") :url)
                     "https://b.example"))
      (should (= 4 (length prefixes)))
      (should (string-match-p "filter(\"\")" (nth 2 prefixes))))))

(ert-deftest chromel-hints-cancel-cleans-up-without-navigation ()
  (with-temp-buffer
    (let ((chromel--id 7) commands)
      (cl-letf (((symbol-function 'chromel--command)
                 (lambda (&rest args) (push args commands)))
                ((symbol-function 'chromel--eval)
                 (lambda (_) '((:label "a" :url "https://example.org"))))
                ((symbol-function 'read-key) (lambda (&rest _) (signal 'quit nil))))
        (should (eq 'cancelled (condition-case nil (chromel-follow) (quit 'cancelled))))
        (should (equal (mapcar #'car (reverse commands)) '("unfocus" "javascript")))
        (should (string-match-p "clear()" (cadar commands)))))))

(ert-deftest chromel-hints-new-buffer-uses-modified-click ()
  (with-temp-buffer
    (let ((chromel--id 7) (chromel--url "https://source.example") (requests 0) commands)
      (cl-letf (((symbol-function 'chromel--command)
                 (lambda (&rest args) (push args commands)))
                ((symbol-function 'chromel--eval)
                 (lambda (_)
                   (if (= 1 (cl-incf requests)) '((:label "a" :url "https://example.org/中文"))
                     '(:action "click" :x 10 :y 20 :link t))))
                ((symbol-function 'chromel--read-hint) (lambda (hints _) (car hints))))
        (chromel-follow-new-buffer)
        (should (equal chromel--url "https://source.example"))
        (should (equal (mapcar #'car (reverse commands)) '("unfocus" "click" "javascript")))
        (should (eq t (plist-get (json-parse-string (cadr (assoc "click" commands))
                                                  :object-type 'plist) :newBuffer)))))))

(ert-deftest chromel-hints-button-in-new-buffer-mode-still-clicks-in-place ()
  (with-temp-buffer
    (let ((chromel--id 7) (requests 0) commands)
      (cl-letf (((symbol-function 'chromel--command) (lambda (&rest args) (push args commands)))
                ((symbol-function 'chromel--eval)
                 (lambda (_) (if (= 1 (cl-incf requests)) '((:label "a"))
                               '(:action "click" :x 10 :y 20 :link :false))))
                ((symbol-function 'chromel--read-hint) (lambda (hints _) (car hints))))
        (chromel-follow-new-buffer)
        (should (eq :false (plist-get (json-parse-string (cadr (assoc "click" commands))
                                                       :object-type 'plist) :newBuffer)))))))

(ert-deftest chromel-hints-editable-is-focused-and-stale-target-is-not-clicked ()
  (dolist (action '((:action "focus") nil))
    (with-temp-buffer
      (let ((chromel--id 7) (requests 0) commands)
        (cl-letf (((symbol-function 'chromel--command) (lambda (&rest args) (push args commands)))
                  ((symbol-function 'chromel--eval)
                   (lambda (_) (if (= 1 (cl-incf requests)) '((:label "a")) action)))
                  ((symbol-function 'chromel--read-hint) (lambda (hints _) (car hints))))
          (if action (chromel-follow) (should-error (chromel-follow) :type 'user-error))
          (should-not (assoc "click" commands))
          (should (eq (not (null (assoc "focus" commands))) (not (null action)))))))))

(ert-deftest chromel-eval-ignores-late-response ()
  (let ((chromel--pages (make-hash-table)))
    (with-temp-buffer
      (setq-local chromel--eval-token "current")
      (puthash 7 (current-buffer) chromel--pages)
      (chromel--handle-event (list :id 7 :type "eval"
                              :value (chromel--json '(:token "old" :ok t :result "[]"))))
      (should-not chromel--eval-reply)
      (chromel--handle-event (list :id 7 :type "eval"
                              :value (chromel--json '(:token "current" :ok t :result "[]"))))
      (should (equal (plist-get chromel--eval-reply :token) "current")))))

(ert-deftest chromel-url-input ()
  (should (equal (chromel--normalize-url " example.org:8080/path ") "https://example.org:8080/path"))
  (should (equal (chromel--normalize-url "localhost:8000/a") "http://localhost:8000/a"))
  (should (equal (chromel--normalize-url "https://example.org/a?q=x") "https://example.org/a?q=x"))
  (should (equal (chromel--normalize-url "about:blank") "about:blank"))
  (should (equal (chromel--normalize-url "data:text/html,hello") "data:text/html,hello"))
  (should (equal (chromel--normalize-url "emacs browser")
                 "https://duckduckgo.com/?q=emacs%20browser"))
  (should (equal (chromel--normalize-url "100% coverage")
                 "https://duckduckgo.com/?q=100%25%20coverage")))

(ert-deftest chromel-search-url-is-customizable ()
  "The search entry point must follow `chromel-search-url'."
  (let ((chromel-search-url "https://search.example.org/f?q=%s"))
    (should (equal (chromel--normalize-url "emacs cef")
                   "https://search.example.org/f?q=emacs%20cef"))))

(ert-deftest chromel-history-roundtrip-dedup-and-limit ()
  (let ((chromel-data-directory (make-temp-file "chromel-history-" t))
        (chromel--history nil) (chromel--history-loaded t)
        (chromel--history-timer nil) (chromel-history-limit 2))
    (unwind-protect
        (progn
          (chromel--history-record "https://a.example" "a")
          (chromel--history-record "https://b.example" "b")
          (chromel--history-record "https://a.example" "updated")
          (chromel--history-record "https://c.example" "c")
          (chromel--history-record "data:text/html,private" "private")
          (should (= 2 (length chromel--history)))
          (should (equal (plist-get (cadr chromel--history) :title) "updated"))
          (cancel-timer chromel--history-timer)
          (chromel--history-save)
          (should (= #o600 (file-modes (expand-file-name "history.json" chromel-data-directory))))
          (setq chromel--history nil chromel--history-loaded nil)
          (chromel--history-load)
          (should (equal (mapcar (lambda (x) (plist-get x :url)) chromel--history)
                         '("https://c.example" "https://a.example"))))
      (when (timerp chromel--history-timer) (cancel-timer chromel--history-timer))
      (delete-directory chromel-data-directory t))))

(ert-deftest chromel-history-unicode-without-coding-prompt ()
  (let* ((chromel-data-directory (make-temp-file "chromel-history-unicode-" t))
         (entry (list :url "https://example.org/中文?q=café"
                      :title "中文页面 😀 — café" :time 1.0))
         (chromel--history (list entry)) (chromel--history-loaded t)
         (chromel--history-timer nil))
    (unwind-protect
        (cl-letf (((symbol-function 'read-coding-system)
                   (lambda (&rest _) (ert-fail "History must not prompt for an encoding"))))
          ;; Exercise the normal write path before testing ambient overrides.
          (chromel--history-save)
          (let ((coding-system-for-write 'iso-latin-1)
                (coding-system-for-read 'iso-latin-1))
            (chromel--history-save)
            (let ((bytes (with-temp-buffer
                           (set-buffer-multibyte nil)
                           (insert-file-contents-literally
                            (expand-file-name "history.json" chromel-data-directory))
                           (buffer-string))))
              (should (string-match-p
                       (regexp-quote (encode-coding-string (plist-get entry :title) 'utf-8-unix))
                       bytes)))
            (setq chromel--history nil chromel--history-loaded nil)
            (chromel--history-load)
            (should (equal chromel--history (list entry)))))
      (delete-directory chromel-data-directory t))))

(ert-deftest chromel-corrupt-history-is-not-overwritten ()
  (let ((chromel-data-directory (make-temp-file "chromel-history-" t))
        (chromel--history nil) (chromel--history-loaded nil))
    (unwind-protect
        (let ((file (expand-file-name "history.json" chromel-data-directory)))
          (with-temp-file file (insert "broken json"))
          (chromel--history-load)
          (chromel--history-save)
          (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                         "broken json")))
      (delete-directory chromel-data-directory t))))

(ert-deftest chromel-layout-follows-selected-split-and-hides ()
  (let ((chromel--initialized t) (chromel--pages (make-hash-table))
        (buffer (generate-new-buffer " *chromel-test*")) layouts hidden)
    (cl-letf (((symbol-function 'chromel--frame-handle) (lambda (_) 91))
              ((symbol-function 'frame-visible-p) (lambda (_) t))
              ((symbol-function 'chromel--native-layout) (lambda (&rest args) (push args layouts)))
              ((symbol-function 'chromel--native-hide) (lambda (id) (push id hidden)))
              ((symbol-function 'chromel--native-command) #'ignore))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (switch-to-buffer buffer)
            (chromel-mode)
            (setq chromel--id 7)
            (puthash 7 buffer chromel--pages)
            (let ((right (split-window-right)))
              (set-window-buffer right buffer)
              (select-window right)
              (chromel--sync)
              (should (eq (buffer-local-value 'chromel--window buffer) right))
              (should (= (nth 2 (car layouts)) (car (window-inside-pixel-edges right)))))
            (delete-other-windows)
            (switch-to-buffer (get-buffer-create " *chromel-test-other*"))
            (chromel--sync)
            (should (equal hidden '(7))))
        (kill-buffer buffer)
        (when (get-buffer " *chromel-test-other*") (kill-buffer " *chromel-test-other*"))))))

(ert-deftest chromel-frame-title-restored-on-binding-failure ()
  (let ((chromel--frames (make-hash-table))
        (old (frame-parameter nil 'title)))
    (cl-letf (((symbol-function 'chromel--native-bind) (lambda (_) (error "bind failure"))))
      (should-error (chromel--frame-handle (selected-frame)))
      (should (equal old (frame-parameter nil 'title)))
      (should (= 0 (hash-table-count chromel--frames))))))

(ert-deftest chromel-changing-major-mode-releases-browser ()
  (let ((chromel--pages (make-hash-table)) commands)
    (cl-letf (((symbol-function 'chromel--native-command)
               (lambda (&rest args) (push args commands))))
      (with-temp-buffer
        (chromel-mode)
        (setq chromel--id 17)
        (puthash 17 (current-buffer) chromel--pages)
        (fundamental-mode)
        (should (equal commands '((17 "close" ""))))
        (should (= 0 (hash-table-count chromel--pages)))))))

(ert-deftest chromel-late-events-for-killed-buffers-are-ignored ()
  (let ((chromel--pages (make-hash-table)))
    (should-not (chromel--handle-event '(:id 99 :type "popup" :value "https://example.org")))))

(ert-deftest chromel-background-focus-does-not-dismiss-minibuffer ()
  (let ((chromel--pages (make-hash-table)) selected)
    (with-temp-buffer
      (setq-local chromel--window (selected-window))
      (puthash 5 (current-buffer) chromel--pages)
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () t))
                ((symbol-function 'select-window) (lambda (&rest _) (setq selected t))))
        (chromel--handle-event '(:id 5 :type "focus"))
        (should-not selected)))))

(ert-deftest chromel-find-cancel-clears-highlights-and-keeps-last-query ()
  (with-temp-buffer
    (let ((chromel--id 7) (chromel--find-active t) (chromel--find-text "previous")
          (chromel--find-status " Find 2/3") commands)
      (cl-letf (((symbol-function 'read-from-minibuffer) (lambda (&rest _) (signal 'quit nil)))
                ((symbol-function 'chromel--command) (lambda (&rest args) (push args commands))))
        (should (eq 'cancelled (condition-case nil (chromel-find) (quit 'cancelled))))
        (should (assoc "find-stop" commands))
        (should-not chromel--find-active)
        (should (equal chromel--find-status ""))
        (should (equal chromel--find-text "previous"))))))

(ert-deftest chromel-find-late-result-does-not-complete-current-query ()
  (let ((chromel--pages (make-hash-table)))
    (with-temp-buffer
      (puthash 7 (current-buffer) chromel--pages)
      (setq-local chromel--find-token "new")
      (chromel--handle-event (list :id 7 :type "find" :value
                              (chromel--json '(:token "old" :count 20 :ordinal 10 :final t))))
      (should-not chromel--find-reply)
      (should (= chromel--find-count 0))
      (chromel--handle-event (list :id 7 :type "find" :value
                              (chromel--json '(:token "new" :count 3 :ordinal 1 :final :false))))
      (should-not chromel--find-reply)
      (chromel--handle-event (list :id 7 :type "find" :value
                              (chromel--json '(:token "new" :count -1 :ordinal 2 :final t))))
      (should (= chromel--find-count 3))
      (should (= chromel--find-ordinal 2))
      (should chromel--find-reply))))

(ert-deftest chromel-copy-link-revalidates-and-does-not-copy-stale-url ()
  (with-temp-buffer
    (let ((chromel--id 7) (calls 0) commands copied)
      (cl-letf (((symbol-function 'chromel--command) (lambda (&rest args) (push args commands)))
                ((symbol-function 'chromel--eval)
                 (lambda (_) (if (= 1 (cl-incf calls)) '((:label "a" :url "https://old.example")) :null)))
                ((symbol-function 'chromel--read-hint) (lambda (hints _) (car hints)))
                ((symbol-function 'kill-new) (lambda (&rest _) (setq copied t))))
        (should-error (chromel-copy-link) :type 'user-error)
        (should-not copied)
        (should-not (assoc "click" commands))
        (should (assoc "javascript" commands))))))

(ert-deftest chromel-hints-background-preserves-source-and-uses-command-click ()
  (with-temp-buffer
    (let ((chromel--id 7) (requests 0) commands (source (current-buffer)))
      (cl-letf (((symbol-function 'chromel--command) (lambda (&rest args) (push args commands)))
                ((symbol-function 'chromel--eval)
                 (lambda (_) (if (= 1 (cl-incf requests)) '((:label "a"))
                               '(:action "click" :x 10 :y 20 :link t))))
                ((symbol-function 'chromel--read-hint) (lambda (hints _) (car hints))))
        (chromel-follow-background)
        (let ((click (json-parse-string (cadr (assoc "click" commands)) :object-type 'plist)))
          (should (eq t (plist-get click :newBuffer)))
          (should (eq t (plist-get click :background))))
        (should (eq source (current-buffer)))))))

(ert-deftest chromel-tab-order-wrap-mru-and-close ()
  (let ((chromel--pages (make-hash-table)) buffers)
    (unwind-protect
        (save-window-excursion
          (dotimes (_ 3)
            (let ((buffer (generate-new-buffer " chromel-tab-test")))
              (push buffer buffers)
              (with-current-buffer buffer (chromel-mode))))
          (setq buffers (nreverse buffers))
          ;; Deliberately insert out of creation order; MRU must not affect gt.
          (puthash 30 (nth 2 buffers) chromel--pages)
          (puthash 10 (nth 0 buffers) chromel--pages)
          (puthash 20 (nth 1 buffers) chromel--pages)
          (cl-letf (((symbol-function 'chromel--command) #'ignore))
            (switch-to-buffer (nth 0 buffers))
            (chromel-next-tab) (should (eq (current-buffer) (nth 1 buffers)))
            (chromel-next-tab) (should (eq (current-buffer) (nth 2 buffers)))
            (chromel-next-tab) (should (eq (current-buffer) (nth 0 buffers)))
            (chromel-previous-tab) (should (eq (current-buffer) (nth 2 buffers)))
            (chromel-last-tab) (should (eq (current-buffer) (nth 0 buffers)))
            (chromel-last-tab) (should (eq (current-buffer) (nth 2 buffers)))
            (chromel-next-tab 5) (should (eq (current-buffer) (nth 1 buffers)))
            ;; A vetoed close must leave both buffer and selection intact.
            (let ((kill-buffer-query-functions (list (lambda () nil))))
              (chromel-close-tab))
            (should (eq (current-buffer) (nth 1 buffers)))
            (should (buffer-live-p (nth 1 buffers)))
            (chromel-close-tab)
            (should-not (buffer-live-p (nth 1 buffers)))
            (should (eq (current-buffer) (nth 2 buffers)))
            (chromel-close-tab)
            (should (eq (current-buffer) (nth 0 buffers)))
            (should-error (chromel-last-tab) :type 'user-error)
            (chromel-close-tab)
            (should-not (chromel--buffers))))
      (dolist (buffer buffers) (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest chromel-tab-picker-filters-non-browser-buffers ()
  (let ((chromel--pages (make-hash-table)) selected)
    (with-temp-buffer
      (let ((browser (current-buffer)))
        (setq-local chromel--url "https://example.org/中文")
        (puthash 1 browser chromel--pages)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_ choices &rest _)
                     (should (= (length choices) 1))
                     (should (string-match-p "中文" (caar choices)))
                     (caar choices)))
                  ((symbol-function 'chromel--select-buffer) (lambda (buffer) (setq selected buffer))))
          (chromel-switch-tab)
          (should (eq selected browser)))))))

(ert-deftest chromel-copied-address-respects-emacs-clipboard-and-target ()
  (let (calls)
    (cl-letf (((symbol-function 'current-kill)
               (lambda (n no-rotate) (should (= n 0)) (should no-rotate) "https://example.org/中文"))
              ((symbol-function 'chromel-open-url) (lambda (url) (push (cons 'current url) calls)))
              ((symbol-function 'chromel-open-new-url) (lambda (url) (push (cons 'new url) calls))))
      (chromel-open-copied-url)
      (chromel-open-copied-url-new-buffer)
      (should (equal (mapcar #'car calls) '(new current))))
    (cl-letf (((symbol-function 'current-kill) (lambda (&rest _) "  ")))
      (should-error (chromel-open-copied-url) :type 'user-error))))

(defun chromel-test--module-available-p ()
  "Return non-nil when the native module has been built on this machine."
  (and (fboundp 'module-load) (file-exists-p chromel-native-module)))

(ert-deftest chromel-settings-routes-without-creating-or-selecting-a-tab ()
  ;; This walks the real settings-URL predicate, which lives in the module.
  (skip-unless (chromel-test--module-available-p))
  ;; Load first: module-load refs every chromel--native-* binding, which would
  ;; replace the stubs installed by cl-letf below.
  (let (calls)
    (chromel--ensure-module)
    (cl-letf (((symbol-function 'chromel--start) #'ignore)
              ((symbol-function 'chromel--native-command) (lambda (&rest args) (push args calls)))
              ((symbol-function 'chromel--make-tab) (lambda (&rest _) (error "Unexpected tab")))
              ((symbol-function 'chromel--select-buffer) (lambda (&rest _) (error "Unexpected selection"))))
      (with-temp-buffer
        (chromel-settings)
        (should (equal (pop calls) '(0 "settings" "")))
        (should-not (chromel "chrome://settings/"))
        (should (equal (pop calls) '(0 "settings" "chrome://settings/")))
        (chromel-open-new-url "chrome://settings/fonts")
        (should (equal (pop calls) '(0 "settings" "chrome://settings/fonts")))
        (chromel-open-url "CHROME://SETTINGS/languages")
        (should (equal (pop calls) '(0 "settings" "chrome://settings/languages")))
        (chromel-passwords)
        (should (equal (pop calls) '(0 "settings" "chrome://password-manager/")))
        (should-not (chromel "CHROME://PASSWORD-MANAGER/passwords"))
        (should (equal (pop calls) '(0 "settings" "chrome://password-manager/passwords")))
        (chromel-open-url "chrome://password-manager/settings")
        (should (equal (pop calls) '(0 "settings" "chrome://password-manager/settings")))
        (chromel-extensions)
        (should (equal (pop calls) '(0 "settings" "chrome://extensions/")))
        (chromel-extension-store)
        (should (equal (pop calls) '(0 "settings" "https://chromewebstore.google.com/")))
        (chromel-open-new-url "https://chromewebstore.google.com/detail/test/abcdefghijklmnop")
        (should (equal (pop calls) '(0 "settings" "https://chromewebstore.google.com/detail/test/abcdefghijklmnop")))
        (dolist (bad '("chrome://extensions.evil/" "https://chromewebstore.google.com.evil/"
                       "https://chromewebstore.google.com@evil/" "http://chromewebstore.google.com/"))
          (should-not (chromel--settings-url-p bad))
          (should-error (chromel-settings bad) :type 'user-error))
        (should-error (chromel-settings "chrome://password-manager.evil/") :type 'user-error)
        (should-error (chromel-settings "chrome://password-manager@evil/") :type 'user-error)
        (should-error (chromel-settings "chrome://settings.evil/") :type 'user-error)
        (should-error (chromel-settings "https://example.org") :type 'user-error)
        (should-not calls)))))

(ert-deftest chromel-management-events-do-not-unfocus-the-source-or-create-tabs ()
  (skip-unless (chromel-test--module-available-p))
  (let ((chromel--pages (make-hash-table)) calls)
    (with-temp-buffer
      (puthash 7 (current-buffer) chromel--pages)
      (chromel--ensure-module) ; see the note in the routing test above
      (cl-letf (((symbol-function 'chromel--start) #'ignore)
                ((symbol-function 'chromel--native-command) (lambda (&rest args) (push args calls)))
                ((symbol-function 'chromel--command) (lambda (&rest _) (error "Unexpected source command")))
                ((symbol-function 'chromel--make-tab) (lambda (&rest _) (error "Unexpected tab"))))
        (dolist (type '("chrome-ui" "popup" "popup-background"))
          (chromel--handle-event (list :id 7 :type type :value "https://chromewebstore.google.com/"))
          (should (equal (pop calls) '(0 "settings" "https://chromewebstore.google.com/"))))
        (should-not calls)))))

(ert-deftest chromel-actions-map-has-no-shadowed-binding ()
  "`s' is page search; the Web Store lives on `E' (README \"页内搜索\")."
  (should (eq (lookup-key chromel-actions-map (kbd "s")) #'chromel-find))
  (should (eq (lookup-key chromel-actions-map (kbd "E")) #'chromel-extension-store))
  (should-not (eq (lookup-key chromel-actions-map (kbd "s")) #'chromel-extension-store)))

(ert-deftest chromel-pump-idles-without-browsers ()
  "No pages and no native browser means the 20 ms pump can stop."
  (let ((chromel--pages (make-hash-table :test #'eq))
        (chromel--tabs nil)
        (chromel--module-loaded t))
    (cl-letf (((symbol-function 'chromel--native-browser-count) (lambda () 0)))
      (should-not (chromel--pump-needed-p))
      (puthash 1 nil chromel--pages)
      (should (chromel--pump-needed-p)))
    ;; A settings window is a browser the page table does not know about.
    (let ((chromel--pages (make-hash-table :test #'eq)))
      (cl-letf (((symbol-function 'chromel--native-browser-count) (lambda () 1)))
        (should (chromel--native-has-browsers-p))
        (should (chromel--pump-needed-p))))))

(ert-deftest chromel-pump-ignores-native-count-before-module-load ()
  (let ((chromel--module-loaded nil))
    (should-not (chromel--native-has-browsers-p))))

(ert-deftest chromel-command-materializes-a-deferred-tab-first ()
  "A pending tab has no browser yet; the command must create it before use."
  (with-temp-buffer
    (setq-local chromel--pending t)
    (let (calls)
      (cl-letf (((symbol-function 'chromel--ensure-browser)
                 (lambda () (push 'ensure calls)
                   (setq-local chromel--pending nil)
                   (setq-local chromel--id 42)))
                ((symbol-function 'chromel--native-command)
                 (lambda (&rest args) (push (cons 'native args) calls))))
        (chromel--command "navigate" "https://example.org/")
        (should (equal (nreverse (mapcar (lambda (c) (if (consp c) (car c) c)) calls))
                       '(ensure native)))
        (should (equal (cdr (car calls)) '(42 "navigate" "https://example.org/")))))))

(ert-deftest chromel-command-refuses-a-tab-that-stayed-deferred ()
  (with-temp-buffer
    (setq-local chromel--pending t)
    (cl-letf (((symbol-function 'chromel--ensure-browser) #'ignore))
      (should-error (chromel--command "reload") :type 'user-error))))

(ert-deftest chromel-tick-keeps-pumping-during-close-grace-period ()
  "Browsers close asynchronously, so the pump must survive an empty page list."
  (let ((chromel--pages (make-hash-table :test #'eq))
        (chromel--tabs nil)
        (chromel--module-loaded t)
        (chromel--idle-since nil)
        (chromel--initialized t)
        (chromel--shutting-down nil)
        (chromel--timer (run-at-time 3600 nil #'ignore)))
    (cl-letf (((symbol-function 'chromel--native-pump) #'ignore)
              ((symbol-function 'chromel--native-events) (lambda () "[]"))
              ((symbol-function 'chromel--native-browser-count) (lambda () 0))
              ((symbol-function 'chromel--sync) #'ignore))
      (chromel--tick)
      (should (timerp chromel--timer))
      (setq chromel--idle-since (time-subtract (current-time) 3))
      (chromel--tick)
      (should-not (timerp chromel--timer)))))

(ert-deftest chromel-browser-count-is-safe-before-cef ()
  "The pump asks for the count before CEF is up, so it must not require CEF."
  (skip-unless (chromel-test--module-available-p))
  (skip-unless (not chromel--initialized))
  (chromel--ensure-module)
  (should (eql 0 (chromel--native-browser-count))))

(ert-deftest chromel-module-api-matches-elisp ()
  "The built dylib must report the API this file was written against."
  (skip-unless (chromel-test--module-available-p))
  (chromel--ensure-module)
  (should (eql (chromel--native-api-version) chromel-module-api-version)))

(ert-deftest chromel-module-api-mismatch-is-loud ()
  "A module without the accessor, or with another number, must not run."
  (skip-unless (chromel-test--module-available-p))
  (chromel--ensure-module)
  (cl-letf (((symbol-function 'chromel--native-api-version) nil))
    (should-error (chromel--check-module-api) :type 'user-error))
  (cl-letf (((symbol-function 'chromel--native-api-version) (lambda () 99)))
    (should-error (chromel--check-module-api) :type 'user-error)))

(ert-deftest chromel-crash-event-shows-a-retry-page-and-reload-returns ()
  "A dead renderer must leave a page the user can act on, not a blank tab."
  (with-temp-buffer
    (chromel-mode)
    (setq chromel--id 4242 chromel--url "https://example.test/page")
    (puthash 4242 (current-buffer) chromel--pages)
    (unwind-protect
        (let (calls)
          (cl-letf (((symbol-function 'chromel--command)
                     (lambda (action &optional argument) (push (cons action argument) calls))))
            (chromel--handle-event
             (list :id 4242 :type "crashed"
                   :value "{\"status\":3,\"code\":-3,\"message\":\"boom\"}"))
            (should chromel--crashed)
            (should (equal chromel--crashed-url "https://example.test/page"))
            (should (equal (caar calls) "navigate"))
            (should (string-prefix-p "data:text/html" (cdar calls)))
            (should (string-match-p "boom" (url-unhex-string (cdar calls))))
            (setq calls nil)
            (chromel-reload)
            (should-not chromel--crashed)
            (should (equal calls '(("navigate" . "https://example.test/page"))))))
      (remhash 4242 chromel--pages))))

(ert-deftest chromel-crash-reason-prefers-the-backend-message ()
  "Explain a crash in words; fall back gracefully when the payload is odd."
  (should (equal (chromel--crash-reason "{\"status\":9,\"code\":0,\"message\":\"\"}")
                 "Renderer exited (status 9, code 0)"))
  (should (equal (chromel--crash-reason "{\"status\":8,\"code\":-3,\"message\":\"Oops\"}")
                 "Oops"))
  (should (equal (chromel--crash-reason "not json") "Renderer exited")))

(ert-deftest chromel-download-events-drive-the-mode-line ()
  (with-temp-buffer
    (setq chromel--status "Loading" chromel--download-percent nil)
    (chromel--download-event "{\"state\":\"started\",\"name\":\"a.txt\",\"path\":\"/tmp/a.txt\"}")
    (should (equal chromel--status "Downloading"))
    (chromel--download-event "{\"state\":\"progress\",\"name\":\"a.txt\",\"percent\":42}")
    (should (equal chromel--status "Downloading 42%"))
    (chromel--download-event "{\"state\":\"progress\",\"name\":\"a.txt\",\"percent\":42}")
    (should (equal chromel--status "Downloading 42%"))
    (chromel--download-event "{\"state\":\"completed\",\"name\":\"a.txt\",\"path\":\"/tmp/a.txt\"}")
    (should (equal chromel--status ""))
    (should (null chromel--download-percent))))

(defvar chromel-test--reported nil)

(ert-deftest chromel-download-failure-keeps-the-page-readable ()
  (setq chromel-test--reported nil)
  (cl-letf (((symbol-function 'message)
             (lambda (format-string &rest args)
               (setq chromel-test--reported (apply #'format format-string args)))))
    (with-temp-buffer
      (setq chromel--status "Downloading" chromel--download-percent 10)
      (chromel--download-event
       "{\"state\":\"failed\",\"name\":\"a.txt\",\"reason\":\"No download directory is configured\"}")
      (should (equal chromel--status ""))
      (should (null chromel--download-percent))))
  (should (string-match-p "No download directory" chromel-test--reported)))

(defun chromel-test--permission-payload (id origin names)
  (json-serialize (list :id id :origin origin :permissions (vconcat names))))

(ert-deftest chromel-permission-policy-answers-without-asking ()
  "A policy answer never reaches the prompt."
  (let ((chromel-permission-policy '(("location" . deny)))
        (asked nil)
        (replies nil))
    (cl-letf (((symbol-function 'chromel--permission-ask)
               (lambda (&rest _) (setq asked t) t))
              ((symbol-function 'chromel--native-permission-reply)
               (lambda (id decision) (push (cons id decision) replies))))
      (chromel--permission-request
       (chromel-test--permission-payload 11 "https://example.org" '("location"))))
    (should-not asked)
    (should (equal replies '((11 . "deny"))))))

(ert-deftest chromel-permission-asks-once-then-remembers ()
  "The first request prompts; the same origin and name are not asked twice."
  (let ((chromel-permission-policy nil)
        (asked 0)
        (replies nil))
    (clrhash chromel--permission-answers)
    (cl-letf (((symbol-function 'chromel--permission-ask)
               (lambda (&rest _) (cl-incf asked) t))
              ((symbol-function 'chromel--native-permission-reply)
               (lambda (id decision) (push (cons id decision) replies))))
      (chromel--permission-request
       (chromel-test--permission-payload 1 "https://example.org" '("notifications")))
      (chromel--permission-request
       (chromel-test--permission-payload 2 "https://example.org" '("notifications"))))
    (should (= asked 1))
    (should (equal (nreverse replies) '((1 . "allow") (2 . "allow"))))))

(ert-deftest chromel-permission-remembers-a-refusal ()
  "Saying no is remembered too, so the page stops nagging."
  (let ((chromel-permission-policy nil)
        (asked 0)
        (replies nil))
    (clrhash chromel--permission-answers)
    (cl-letf (((symbol-function 'chromel--permission-ask)
               (lambda (&rest _) (cl-incf asked) nil))
              ((symbol-function 'chromel--native-permission-reply)
               (lambda (id decision) (push (cons id decision) replies))))
      (chromel--permission-request
       (chromel-test--permission-payload 5 "https://example.org" '("camera")))
      (chromel--permission-request
       (chromel-test--permission-payload 6 "https://example.org" '("camera"))))
    (should (= asked 1))
    (should (equal (nreverse replies) '((5 . "deny") (6 . "deny"))))))

(ert-deftest chromel-permission-policy-denial-refuses-the-whole-request ()
  "One denied name cannot be split out of a single callback, so all of it is denied."
  (let ((chromel-permission-policy '(("camera" . deny)))
        (asked nil)
        (replies nil))
    (clrhash chromel--permission-answers)
    (cl-letf (((symbol-function 'chromel--permission-ask)
               (lambda (&rest _) (setq asked t) t))
              ((symbol-function 'chromel--native-permission-reply)
               (lambda (id decision) (push (cons id decision) replies))))
      (chromel--permission-request
       (chromel-test--permission-payload 9 "https://example.org" '("camera" "microphone"))))
    (should-not asked)
    (should (equal replies '((9 . "deny"))))))

(defun chromel-test--http-get (port path)
  "Return the body of GET PATH from 127.0.0.1:PORT."
  (let* ((response "")
         (process (make-network-process
                   :name "chromel-pac-client" :host "127.0.0.1" :service port
                   :family 'ipv4 :coding 'binary
                   :filter (lambda (_proc chunk)
                             (setq response (concat response chunk)))
                   :sentinel #'ignore)))
    (process-send-string
     process (format "GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n" path))
    (let ((deadline (+ (float-time) 5)))
      (while (and (< (float-time) deadline) (process-live-p process))
        (accept-process-output process 0.05)))
    (when (process-live-p process) (delete-process process))
    (cadr (split-string response "\r\n\r\n"))))

(ert-deftest chromel-pac-url-serves-files-on-loopback ()
  "A path is served over loopback HTTP; a URL is passed through; nil is direct."
  (should (equal (chromel--pac-url nil) ""))
  (should (equal (chromel--pac-url "http://example.org/proxy.pac")
                 "http://example.org/proxy.pac"))
  (let ((file (make-temp-file "chromel-pac" nil ".pac"))
        (body "function FindProxyForURL(url, host) { return \"DIRECT\"; }\n"))
    (unwind-protect
        (progn
          (with-temp-file file (insert body))
          (let ((url (chromel--pac-url file)))
            (should (string-match-p
                     "\\`http://127\\.0\\.0\\.1:[0-9]+/proxy\\.pac\\'" url))
            (should (equal (chromel-test--http-get
                            (process-contact chromel--pac-server :service)
                            "/proxy.pac")
                           body))))
      (when (process-live-p chromel--pac-server)
        (delete-process chromel--pac-server))
      (setq chromel--pac-server nil)
      (delete-file file))))

(ert-deftest chromel-blocklist-blocks-hosts-and-respects-allow ()
  (skip-unless (chromel-test--module-available-p))
  (chromel--ensure-module)
  (let ((file (make-temp-file "chromel-bl" nil ".txt")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# chromel-blocklist 1\n"
                    "b\t0\t\th=ads.example.com\n"
                    "a\t0\t\th=safe.ads.example.com\n"))
          (chromel--native-blocklist-load file)
          (should (chromel--native-blocklist-blocks "http://ads.example.com/x.js" 3 ""))
          (should-not (chromel--native-blocklist-blocks "http://safe.ads.example.com/x.js" 3 "")))
      (delete-file file))))

(ert-deftest chromel-blocklist-smells-host-case-and-port ()
  (skip-unless (chromel-test--module-available-p))
  (chromel--ensure-module)
  (let ((file (make-temp-file "chromel-bl" nil ".txt")))
    (unwind-protect
        (progn (with-temp-file file (insert "b\t0\t\th=ads.example.com\n"))
               (chromel--native-blocklist-load file)
               (should (chromel--native-blocklist-blocks "http://Ads.Example.COM:8080/a" 4 "")))
      (delete-file file))))

(ert-deftest chromel-blocklist-honours-resource-types ()
  (skip-unless (chromel-test--module-available-p))
  (chromel--ensure-module)
  (let ((file (make-temp-file "chromel-bl" nil ".txt")))
    (unwind-protect
        (progn (with-temp-file file (insert (format "b\t%x\t\th=ads.example.com\n" (ash 1 3))))
               (chromel--native-blocklist-load file)
               (should (chromel--native-blocklist-blocks "http://ads.example.com/a.js" 3 ""))
               (should-not (chromel--native-blocklist-blocks "http://ads.example.com/a.png" 4 "")))
      (delete-file file))))

(ert-deftest chromel-blocklist-maps-cef-types-onto-mask-bits ()
  (skip-unless (chromel-test--module-available-p))
  (chromel--ensure-module)
  (let ((file (make-temp-file "chromel-bl" nil ".txt")))
    (unwind-protect
        (progn
          ;; bit 7 is XHR in the converter's order; CEF calls that type 13.
          (with-temp-file file (insert (format "b\t%x\t\th=ads.example.com\n" (ash 1 7))))
          (chromel--native-blocklist-load file)
          (should (chromel--native-blocklist-blocks "http://ads.example.com/api" 13 ""))
          (should-not (chromel--native-blocklist-blocks "http://ads.example.com/pre" 11 "")))
      (delete-file file))))

(ert-deftest chromel-blocklist-missing-file-reports-an-error ()
  (skip-unless (chromel-test--module-available-p))
  (chromel--ensure-module)
  (should-error (chromel--native-blocklist-load "/nonexistent/blocklist.txt")))
