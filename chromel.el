;;; chromel.el --- Native CEF browser buffers for macOS -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1"))
;; Version: 0.1.0
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Load chromel.el, then M-x chromel.  Run scripts/build.sh before first use.
;; Each browser is an in-process Cocoa child view, with CEF renderer helpers.
;; No Qt, external floating window, or patched Emacs is required.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'seq)
(require 'url-parse)
(require 'url-util)

(defgroup chromel nil "Native browser buffers." :group 'applications)
(defconst chromel--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory)))
(defcustom chromel-native-module (expand-file-name "build/chromel-module.dylib" chromel--directory)
  "Compiled native module." :type 'file)
(defcustom chromel-runtime-directory (expand-file-name "build/ChromelRuntime.app" chromel--directory)
  "CEF runtime bundle." :type 'directory)
(defun chromel--default-data-directory ()
  "Prefer Chromel data, reusing an existing Web directory on upgrade."
  (let ((current (expand-file-name "chromel/" user-emacs-directory))
        (legacy (expand-file-name "web/" user-emacs-directory)))
    (if (and (not (file-exists-p current)) (file-directory-p legacy))
        legacy
      current)))

(defcustom chromel-data-directory (chromel--default-data-directory)
  "Private directory for CEF profile and browsing history.
Defaults to chromel/ under `user-emacs-directory', or an existing web/
directory when chromel/ does not exist.  No data is moved automatically.
Do not point this at a Chrome profile.  Restart Emacs after changing it."
  :type 'directory)
(defcustom chromel-home-url "https://example.org"
  "Page opened by `chromel' when no URL is supplied." :type 'string)
(defcustom chromel-allow-raw-javascript t
  "Allow the fire-and-forget JavaScript channel from Lisp.
The `javascript' browser action runs a script on the main frame and discards
its result, so nothing can report success or failure.  Set this to nil to
confine scripting to the tokenized `chromel--eval' path; hint overlays then
cannot clean themselves up, so re-run `chromel-follow' to clear them."
  :type 'boolean)
(defcustom chromel-history-limit 1000 "Maximum number of saved history entries."
  :type 'natnum)
(defcustom chromel-closed-tab-limit 30
  "Maximum number of closed pages retained for `chromel-reopen-closed-tab'."
  :type 'natnum)
(defcustom chromel-session-auto-save t
  "Automatically save browser tabs after changes and on Emacs exit."
  :type 'boolean)
(defcustom chromel-hint-alphabet "asdfghjklqwertyuiopzxcvbnm"
  "Distinct lowercase ASCII letters used for interactive element labels."
  :type 'string)
(defcustom chromel-scroll-step 60
  "Distance in CSS pixels scrolled by one j or k command."
  :type 'natnum)
(defcustom chromel-scroll-duration 140
  "Approximate smooth scrolling duration in milliseconds.
Set to zero for instant scrolling.  The system reduced-motion preference
also disables animation.  Separate commands accumulate their distance.
Held j/k use `chromel-scroll-speed` after the initial step."
  :type 'natnum)

(defcustom chromel-scroll-speed 900
  "Continuous j/k scrolling speed in CSS pixels per second."
  :type 'natnum)
(defvar-local chromel--scroll-settings nil)

(declare-function chromel--native-init "chromel-module" (bundle profile))
(declare-function chromel--native-bind "chromel-module" (title))
(declare-function chromel--native-create "chromel-module" (window url))
(declare-function chromel--native-layout "chromel-module" (id window x y width height))
(declare-function chromel--native-hide "chromel-module" (id))
(declare-function chromel--native-command "chromel-module" (id action argument))
(declare-function chromel--native-pump "chromel-module" ())
(declare-function chromel--native-events "chromel-module" ())
(declare-function chromel--native-shutdown "chromel-module" ())
(declare-function chromel--native-info "chromel-module" ())
(declare-function chromel--native-inspect "chromel-module" (id))

(defvar chromel--initialized nil)
(defvar chromel--timer nil)
(defvar chromel--syncing nil)
(defvar chromel--pages (make-hash-table :test #'eql))
(defvar chromel--frames (make-hash-table :test #'eq :weakness 'key))
(defvar chromel--history nil)
(defvar chromel--history-loaded nil)
(defvar chromel--history-timer nil)
(defvar chromel--tabs nil)
(defvar chromel--closed-tabs nil)
(defvar chromel--last-selected-tab nil)
(defvar chromel--session-loaded nil)
(defvar chromel--previous-session nil)
(defvar chromel--session-restored nil)
(defvar chromel--session-backed-up nil)
(defvar chromel--session-active nil)
(defvar chromel--session-dirty nil)
(defvar chromel--session-timer nil)
(defvar chromel--session-inhibit nil)
(defvar chromel--shutting-down nil)
(defvar chromel--eval-counter 0)
(defvar-local chromel--id nil)
(defvar-local chromel--pending nil)
(defvar-local chromel--activation-error nil)
(defvar-local chromel--url "")
(defvar-local chromel--title "Browser")
(defvar-local chromel--status "")
(defvar-local chromel--window nil)
(defvar-local chromel--find-token nil)
(defvar-local chromel--find-reply nil)
(defvar-local chromel--find-text "")
(defvar-local chromel--find-active nil)
(defvar-local chromel--find-count 0)
(defvar-local chromel--find-ordinal 0)
(defvar-local chromel--find-status "")
(defvar-local chromel--eval-token nil)
(defvar-local chromel--eval-reply nil)

(defun chromel--normalize-url (input)
  "Convert INPUT to a navigable URL.  Whitespace-separated input is a search."
  (setq input (string-trim input))
  (cond ((string-empty-p input) chromel-home-url)
        ((string-match-p "\\`\\(?:[[:alpha:]][[:alnum:]+.-]*://\\|about:\\|data:\\)" input) input)
        ((file-name-absolute-p input)
         (concat "file://" (url-encode-url (expand-file-name input))))
        ((string-match-p "[[:space:]]" input)
         (concat "https://duckduckgo.com/?q=" (url-hexify-string input)))
        ((string-match-p "\\`\\(?:localhost\\|127\\.0\\.0\\.1\\|\\[::1\\]\\)\\(?::[0-9]+\\)?\\(?:/\\|\\'\\)" input)
         (concat "http://" input))
        (t (concat "https://" input))))

(defun chromel--header-url (url)
  "Shorten HTTP(S) URL to its origin and an ellipsis for hidden details."
  (save-match-data
    (if (string-match "\\`\\(https?://[^/?#]+\\)\\(.*\\)\\'" url)
        (concat (match-string 1 url)
                (unless (member (match-string 2 url) '("" "/")) "/..."))
      url)))

(defconst chromel--header-line-format '(:eval (concat " " (chromel--header-url chromel--url))))

(defun chromel--start ()
  (chromel--session-load)
  (unless chromel--initialized
    (unless (and (eq system-type 'darwin) (eq window-system 'ns)
                 (fboundp 'module-load))
      (user-error "Chromel requires a Cocoa Emacs with dynamic module support"))
    (unless (file-exists-p chromel-native-module)
      (user-error "Build the module first: cd %s && ./scripts/build.sh" chromel--directory))
    (make-directory chromel-data-directory t)
    (set-file-modes chromel-data-directory #o700)
    (chromel--ensure-module)
    ;; Chromium's macOS sandbox authorizes MainBundlePath, not CEF's outer
    ;; bundle override.  The launcher supplies an unchanged Emacs binary in
    ;; a private bundle with the framework physically inside it.
    (let ((host (expand-file-name "../.." invocation-directory)))
      (when (file-directory-p
             (expand-file-name "Contents/Frameworks/Chromium Embedded Framework.framework" host))
        (setq chromel-runtime-directory host)))
    (chromel--native-init (directory-file-name (expand-file-name chromel-runtime-directory))
                      (expand-file-name "profile" chromel-data-directory))
    (setq chromel--initialized t)
    (chromel--history-load)
    (add-hook 'window-size-change-functions #'chromel--sync)
    (add-hook 'window-buffer-change-functions #'chromel--sync)
    (add-hook 'window-selection-change-functions #'chromel--sync)
    (add-hook 'window-configuration-change-hook #'chromel--sync)
    (add-hook 'minibuffer-setup-hook #'chromel--release-focus)
    (add-hook 'delete-frame-functions #'chromel--frame-deleting)
    (add-hook 'kill-emacs-hook #'chromel--shutdown)
    (setq chromel--timer (run-at-time 0 0.02 #'chromel--tick))))

(defun chromel--frame-handle (frame)
  "Bind FRAME to an NSWindow without depending on private Emacs structs."
  (or (gethash frame chromel--frames)
      (let ((old (frame-parameter frame 'title))
            (token (format "emacs-chromel-%s-%s" (emacs-pid) (make-temp-name "frame-"))))
        (unwind-protect
            (progn
              ;; NS `window-id' is an Emacs counter, not an NSWindow pointer.
              (set-frame-parameter frame 'title token)
              (let ((handle (chromel--native-bind token)))
                (puthash frame handle chromel--frames)
                handle))
          (set-frame-parameter frame 'title old)))))

(defun chromel--display-window (buffer)
  "Choose one visible window for BUFFER, preferring the selected window."
  (let ((windows (get-buffer-window-list buffer nil t)))
    (or (and (memq (selected-window) windows) (selected-window))
        (cl-find-if (lambda (w) (eq t (frame-visible-p (window-frame w)))) windows))))

(defun chromel--sync (&rest _)
  "Synchronize native views with Emacs windows, in Cocoa logical points."
  (when (and chromel--initialized (not chromel--syncing) (not chromel--shutting-down))
    (let* ((chromel--syncing t)
           (selected (window-buffer (selected-window))))
      (when (and (not chromel--session-inhibit) (not chromel--shutting-down)
                 (not (active-minibuffer-window)) (memq selected (chromel--buffers)))
        (with-current-buffer selected
          (when (and chromel--pending (not chromel--activation-error))
            (condition-case err
                (chromel--ensure-browser)
              (error
               (setq chromel--activation-error (error-message-string err)
                     chromel--status "Load failed; r to retry")
               (message "Chromel: %s" chromel--activation-error)))))
        (unless (eq selected chromel--last-selected-tab)
          (setq chromel--last-selected-tab selected)
          (chromel--session-changed)))
      (maphash
       (lambda (id buffer)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (let ((win (chromel--display-window buffer)))
               (setq chromel--window win)
               (let ((settings (list chromel-scroll-step chromel-scroll-duration chromel-scroll-speed)))
                 (unless (equal settings chromel--scroll-settings)
                   (chromel--native-command id "scroll-settings" (chromel--json (vconcat settings)))
                   (setq chromel--scroll-settings settings)))
               ;; Cocoa may consume Escape before Emacs keymaps see it.  Tell
               ;; the native event router which buffer owns command input.
               (chromel--native-command id "selected"
                                    (if (and (eq win (selected-window))
                                             (not (active-minibuffer-window))) "1" "0"))
               (if (and win (eq t (frame-visible-p (window-frame win))))
                   (pcase-let ((`(,left ,top ,right ,bottom)
                                (window-inside-pixel-edges win)))
                     (chromel--native-layout id (chromel--frame-handle (window-frame win))
                                         left top (- right left) (- bottom top))
                     (unless (and (eq win (selected-window))
                                  (not (active-minibuffer-window)))
                       (chromel--native-command id "unfocus" "")))
                 (chromel--native-hide id))))))
       chromel--pages))))

(defun chromel--release-focus ()
  (when chromel--initialized
    (maphash (lambda (id _)
               (chromel--native-command id "selected" "0")
               (chromel--native-command id "unfocus" "")) chromel--pages)))

(defun chromel--frame-deleting (frame)
  (maphash
   (lambda (id buffer)
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (when (and (window-live-p chromel--window)
                    (eq frame (window-frame chromel--window)))
           (chromel--native-hide id)
           (setq chromel--window nil)))))
   chromel--pages)
  (remhash frame chromel--frames))

(defun chromel--handle-event (event)
  (let* ((id (plist-get event :id))
         (buffer (gethash id chromel--pages))
         (type (plist-get event :type))
         (value (or (plist-get event :value) "")))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (pcase type
          ("title"
           (setq chromel--title value)
           (rename-buffer (format "*chromel: %s*" (truncate-string-to-width value 60)) t))
          ("url"
           (unless (equal value chromel--url)
             (setq chromel--find-active nil chromel--find-status ""))
           (setq chromel--url value))
          ("loading" (setq chromel--status (if (equal value "1") "Loading" "")))
          ("loaded" (chromel--history-record chromel--url chromel--title))
          ("error" (setq chromel--status value))
          ("focus"
           (when (and (window-live-p chromel--window) (not (active-minibuffer-window)))
             (select-window chromel--window)))
          ("scroll-key"
           (let ((request (json-parse-string value :object-type 'plist)))
             (chromel--scroll (plist-get request :steps) (plist-get request :frame))))
          ("find"
           (let ((reply (json-parse-string value :object-type 'plist)))
             (when (equal chromel--find-token (plist-get reply :token))
               (when (>= (plist-get reply :count) 0)
                 (setq chromel--find-count (plist-get reply :count)))
               (when (>= (plist-get reply :ordinal) 0)
                 (setq chromel--find-ordinal (plist-get reply :ordinal)))
               (when (eq t (plist-get reply :final)) (setq chromel--find-reply reply)))))
          ("chrome-ui" (chromel-settings value))
          ("popup-background" (chromel value t))
          ("popup"
           ;; Select the new buffer while keeping browser commands available.
           (when-let* ((target (chromel value)))
             (with-current-buffer target (chromel--command "unfocus"))))
          ("eval"
           (let ((reply (json-parse-string value :object-type 'plist)))
             (when (equal chromel--eval-token (plist-get reply :token))
               (setq chromel--eval-reply reply))))
          ("closed"
           (remhash id chromel--pages)
           (setq chromel--id nil chromel--status "Closed")
           (chromel--kill-buffer)))
        (when (member type '("title" "url")) (chromel--session-changed))
        (force-mode-line-update)))))

(defun chromel--tick ()
  (when chromel--initialized
    (condition-case err
        (progn
          (chromel--native-pump)
          (dolist (event (json-parse-string (chromel--native-events)
                                            :object-type 'plist :array-type 'list))
            (chromel--handle-event event))
          (chromel--sync))
      (error
       ;; Avoid repeated native errors at 50 Hz.  `chromel-resume' retries explicitly.
       (cancel-timer chromel--timer)
       (setq chromel--timer nil)
       (message "Chromel paused: %s (M-x chromel-resume to retry)" (error-message-string err))))))

(defun chromel-resume ()
  "Resume the browser event pump after a reported error."
  (interactive)
  (unless chromel--initialized (user-error "Chromel has not started"))
  (unless chromel--timer (setq chromel--timer (run-at-time 0 0.02 #'chromel--tick))))

(defun chromel--kill-buffer ()
  (let* ((buffer (current-buffer))
         (index (cl-position buffer (chromel--buffers))))
    (when (and index (not chromel--session-inhibit) (not chromel--shutting-down)
               (> chromel-closed-tab-limit 0) (not (string-empty-p chromel--url)))
      (push (list :url chromel--url :title chromel--title :index index) chromel--closed-tabs)
      (setq chromel--closed-tabs (seq-take chromel--closed-tabs chromel-closed-tab-limit)))
    (when chromel--id
      (chromel--native-command chromel--id "close" "")
      (remhash chromel--id chromel--pages))
    (setq chromel--id nil chromel--pending nil
          chromel--tabs (delq buffer chromel--tabs))
    (when index (chromel--session-changed))))

(defun chromel--shutdown ()
  ;; Save before native shutdown or buffer teardown can discard tab state.
  (when (timerp chromel--session-timer) (cancel-timer chromel--session-timer))
  (setq chromel--session-timer nil)
  (when (and chromel-session-auto-save chromel--session-active)
    (chromel--session-save-quietly))
  (setq chromel--shutting-down t)
  (when (timerp chromel--timer) (cancel-timer chromel--timer))
  (when (timerp chromel--history-timer) (cancel-timer chromel--history-timer))
  (chromel--history-save)
  (when chromel--initialized
    ;; Let Emacs dispatch Cocoa events between close requests and CefShutdown.
    ;; Blocking inside the native shutdown loop alone can leave AppKit window
    ;; teardown pending and skip CEF's profile flush when tabs are still open.
    (chromel--native-command 0 "close-settings" "")
    (dolist (buffer (chromel--buffers))
      (with-current-buffer buffer (ignore-errors (chromel--kill-buffer))))
    (let ((deadline (+ (float-time) 3)))
      (while (and (< (float-time) deadline)
                  (let ((info (chromel--native-info)))
                    (not (and (string-match-p "Browsers including DevTools: 0" info)
                              (string-match-p "Settings windows: 0" info)))))
        (chromel--native-pump)
        (accept-process-output nil 0.01)))
    (chromel--native-shutdown)))

(defvar chromel-mode-map (make-sparse-keymap)
  "Browser commands, following Vimium's default keys.")

;; Clear the early layout on reload, particularly g before making it a prefix.
(dolist (key '("g" "b" "h"))
  (define-key chromel-mode-map (kbd key) nil))
(dolist (entry '(("r" . chromel-reload) ("gg" . chromel-scroll-to-top)
                 ("G" . chromel-scroll-to-bottom) ("H" . chromel-back) ("L" . chromel-forward)
                 ("j" . chromel-scroll-down) ("k" . chromel-scroll-up)
                 ("d" . chromel-scroll-half-page-down) ("u" . chromel-scroll-half-page-up)
                 ("f" . chromel-follow) ("F" . chromel-follow-background)
                 ("M-f" . chromel-follow-multiple) ("yy" . chromel-copy-url) ("yf" . chromel-copy-link)
                 ("/" . chromel-find) ("n" . chromel-find-next) ("N" . chromel-find-previous)
                 ("o" . chromel-open) ("O" . chromel-open-new-url)
                 ("ge" . chromel-open-url) ("gE" . chromel-edit-url-new-buffer)
                 ("p" . chromel-open-copied-url) ("P" . chromel-open-copied-url-new-buffer)
                 ("t" . chromel-new-tab) ("x" . chromel-close-tab) ("X" . chromel-reopen-closed-tab)
                 ("J" . chromel-previous-tab) ("K" . chromel-next-tab)
                 ("gT" . chromel-previous-tab) ("gt" . chromel-next-tab)
                 ("T" . chromel-switch-tab) ("^" . chromel-last-tab)
                 ("gF" . chromel-focus-main-frame)
                 ("i" . chromel-focus) ("RET" . chromel-focus) ("q" . quit-window)
                 ("M-<" . chromel-scroll-to-top) ("M->" . chromel-scroll-to-bottom)
                 ("M-<right>" . chromel-forward)
                 ("C-c C-f" . chromel-forward) ("C-c C-j" . chromel-follow)
                 ("C-c C-o" . chromel-open-url) ("C-c C-r" . chromel-reload)
                 ("C-c C-i" . chromel-focus) ("C-c C-d" . chromel-devtools)
                 ("C-c C-p" . chromel-focus-parent-frame)))
  (define-key chromel-mode-map (kbd (car entry)) (cdr entry)))

;; Motion leaves other browser keys to the major mode.  Only adapt the two
;; movement commands commonly configured in Meow; keep SPC/keypad untouched.
(define-key chromel-mode-map [remap meow-next] #'chromel-scroll-down)
(define-key chromel-mode-map [remap meow-prev] #'chromel-scroll-up)
(defvar meow-mode-state-list)
(with-eval-after-load 'meow
  ;; Respect an explicit user preference, and support either load order.
  (unless (assq 'chromel-mode meow-mode-state-list)
    (push '(chromel-mode . motion) meow-mode-state-list)))

;; These remain accessible when the native page owns keyboard focus.
(defvar chromel-actions-map (make-sparse-keymap))
(dolist (entry '(("s" . chromel-find) ("n" . chromel-find-next) ("p" . chromel-find-previous)
                 ("c" . chromel-find-clear) ("d" . chromel-scroll-half-page-down)
                 ("u" . chromel-scroll-half-page-up) ("<" . chromel-scroll-to-top)
                 (">" . chromel-scroll-to-bottom) ("y" . chromel-copy-url)
                 ("f" . chromel-copy-link) ("m" . chromel-follow-multiple)
                 ("h" . chromel-history) ("," . chromel-settings) ("P" . chromel-passwords) ("e" . chromel-extensions) ("s" . chromel-extension-store) ("S" . chromel-save-session) ("R" . chromel-restore-session)))
  (define-key chromel-actions-map (kbd (car entry)) (cdr entry)))
(define-key chromel-mode-map (kbd "C-c w") chromel-actions-map)

(define-derived-mode chromel-mode special-mode "Chromel"
  "CEF browser buffer.  Press i to focus the page, Esc or C-g to return to Emacs.
One native view can occupy only one Emacs window at a time."
  ;; Translate the dedicated Escape key before Meow/emulation keymaps.  Keep
  ;; the ESC prefix (used for Meta sequences) and all other buffers unchanged.
  (setq-local key-translation-map (if (keymapp key-translation-map)
                                      (copy-keymap key-translation-map)
                                    (make-sparse-keymap)))
  (define-key key-translation-map [escape] (kbd "C-g"))
  (setq-local cursor-type nil)
  (setq-local truncate-lines t)
  (setq-local header-line-format chromel--header-line-format)
  (setq-local mode-line-process '(:eval (concat " " chromel--status chromel--find-status)))
  (add-hook 'kill-buffer-hook #'chromel--kill-buffer nil t)
  (add-hook 'change-major-mode-hook #'chromel--kill-buffer nil t)
  (let ((inhibit-read-only t))
    (insert "This browser view is displayed in one Emacs window at a time.\n"
            "Select this window to move the view here.\n\n"
            "i: focus page   Esc/C-g: return to Emacs   o: URL   r: reload\n"
            "j: scroll down   k: scroll up\n"
            "C-c C-p: parent page   C-u C-c C-p: outermost page\n"
            "f: click/focus hints   F: open links in the background\n")))

(defun chromel--make-tab (url title &optional position)
  "Create a deferred tab with exact URL and TITLE at POSITION, or at the end."
  (let* ((buffer (generate-new-buffer "*chromel*"))
         (tabs (chromel--buffers))
         (index (min (or position (length tabs)) (length tabs))))
    (with-current-buffer buffer
      (chromel-mode)
      (setq chromel--url url chromel--title title chromel--pending t chromel--status "Not loaded")
      (rename-buffer (format "*chromel: %s*" (truncate-string-to-width title 60)) t))
    (setq chromel--tabs (append (seq-take tabs index) (list buffer) (nthcdr index tabs)))
    buffer))

(defun chromel--ensure-browser ()
  "Materialize the current deferred tab exactly once.  Errors leave it retryable."
  (when chromel--pending
    (chromel--start)
    (let* ((chromel--syncing t)
           (window (chromel--display-window (current-buffer)))
           (id (chromel--native-create (chromel--frame-handle
                                    (if window (window-frame window) (selected-frame)))
                                  chromel--url)))
      (setq chromel--id id chromel--pending nil chromel--activation-error nil chromel--status "Loading")
      (puthash id (current-buffer) chromel--pages))))

;;;###autoload
(defun chromel-settings (&optional url)
  "Open or raise Chromium settings in a separate native window.
The window shares this plugin's profile with embedded pages.  Optional
URL selects a supported Chromium management or Chrome Web Store page;
omitted URL preserves the current page.  Works from any buffer and does
not create a browser tab."
  (interactive)
  (when (and url (not (chromel--settings-url-p url)))
    (user-error "Expected a Chromium management or Chrome Web Store URL"))
  (chromel--start)
  (chromel--native-command 0 "settings"
                       (if url
                           (replace-regexp-in-string
                            "\\`[^/?#]+://[^/?#]+" #'downcase url t t)
                         "")))

;;;###autoload
(defun chromel-passwords ()
  "Open Chromium's password manager using this plugin's shared profile."
  (interactive)
  (chromel-settings "chrome://password-manager/"))

;;;###autoload
(defun chromel-extensions ()
  "Open Chromium extension management for this plugin's profile."
  (interactive)
  (chromel-settings "chrome://extensions/"))

;;;###autoload
(defun chromel-extension-store ()
  "Open the Chrome Web Store in the shared Chrome-style window."
  (interactive)
  (chromel-settings "https://chromewebstore.google.com/"))

(defvar chromel--module-loaded nil
  "Non-nil once the dynamic module is present in this Emacs process.")

(declare-function chromel--native-is-settings-url "chromel-module" (url))

(defun chromel--ensure-module ()
  "Load the dynamic module without starting CEF.
Signal `user-error' naming the library when it cannot be loaded, so a stale
build is not misreported as a bad URL.  Always returns non-nil."
  (unless chromel--module-loaded
    (condition-case err
        (module-load chromel-native-module)
      (error
       (user-error "Cannot load the Chromel native module %s: %s"
                   chromel-native-module (error-message-string err))))
    (setq chromel--module-loaded t))
  t)

(defun chromel--settings-url-p (url)
  "Return non-nil if URL needs the shared Chrome-style management window.
The matching rules live in the native layer, so Lisp and CEF cannot drift apart."
  (and (stringp url)
       (chromel--ensure-module)
       (chromel--native-is-settings-url url)))

;;;###autoload
(defun chromel (&optional url background)
  "Open URL in a new browser buffer.
With BACKGROUND non-nil, leave the selected buffer and keyboard focus alone.
Management and Chrome Web Store URLs open a separate window and return nil."
  (interactive (list (read-string "URL or search: " nil nil chromel-home-url)))
  (setq url (chromel--normalize-url (or url chromel-home-url)))
  (if (chromel--settings-url-p url)
      (progn (chromel-settings url) nil)
    (chromel--start)
    (let (buffer)
      (let ((chromel--session-inhibit t))
        (condition-case err
            (progn
              (setq buffer (chromel--make-tab url "Browser"))
              (unless background (pop-to-buffer buffer))
              (with-current-buffer buffer
                (chromel--ensure-browser)
                (chromel--sync)
                (unless (or background (active-minibuffer-window)) (chromel-focus)))
              (unless background (setq chromel--last-selected-tab buffer)))
          ((error quit)
           (when (buffer-live-p buffer) (kill-buffer buffer))
           (signal (car err) (cdr err)))))
      (chromel--session-changed)
      buffer)))

(defun chromel--command (action &optional argument)
  ;; Check the option before ensure-browser: that call can start CEF and create
  ;; a deferred tab, and a refused action should not have those side effects.
  (when (and (equal action "javascript") (not chromel-allow-raw-javascript))
    (user-error "Raw JavaScript is disabled; see `chromel-allow-raw-javascript'"))
  (chromel--ensure-browser)
  (unless chromel--id (user-error "This is not a live Chromel buffer"))
  (chromel--native-command chromel--id action (or argument "")))

(defun chromel-open-url (url)
  "Navigate the current browser to URL."
  (interactive (list (read-string "URL or search: " chromel--url)))
  (setq url (chromel--normalize-url url))
  (if (chromel--settings-url-p url)
      (chromel-settings url)
    (chromel--command "navigate" url)))
(defvar chromel-url-history nil)

(defun chromel--read-url (&optional initial)
  "Read an address or search, completing visited URLs, with INITIAL text."
  (chromel--history-load)
  (completing-read "URL or search: "
                   (delete-dups (mapcar (lambda (item) (plist-get item :url)) chromel--history))
                   nil nil initial 'chromel-url-history))

(defun chromel-open (url)
  "Open URL in the current page, completing previously visited addresses."
  (interactive (list (chromel--read-url)))
  (chromel-open-url url))

(defun chromel--buffers ()
  "Return browser tabs in tab order, including deferred restored pages."
  ;; Include pre-existing native pages when reloading from an older version.
  (let ((tabs (cl-remove-if-not #'buffer-live-p chromel--tabs)))
    (append tabs
            (mapcar #'cdr
                    (sort (cl-loop for id being the hash-keys of chromel--pages using (hash-values buffer)
                                   when (and (buffer-live-p buffer) (not (memq buffer tabs)))
                                   collect (cons id buffer))
                          (lambda (a b) (< (car a) (car b))))))))

(defun chromel--select-buffer (buffer)
  "Select browser BUFFER in this window, retaining Emacs command focus."
  (unless (memq buffer (chromel--buffers)) (user-error "Browser buffer is no longer live"))
  (chromel--release-focus)
  (switch-to-buffer buffer)
  (chromel--ensure-browser)
  (chromel--sync)
  (chromel--command "unfocus")
  (setq chromel--last-selected-tab buffer)
  (chromel--session-changed))

(defun chromel-open-new-url (url)
  "Open URL in a new selected browser buffer, retaining command focus."
  (interactive (list (chromel--read-url)))
  (when-let* ((buffer (chromel url t)))
    (chromel--select-buffer buffer)))

(defun chromel-edit-url-new-buffer (url)
  "Edit this page's address and open URL in a new browser buffer."
  (interactive (list (chromel--read-url chromel--url)))
  (chromel-open-new-url url))

(defun chromel-new-tab ()
  "Open `chromel-home-url' in a new selected browser buffer."
  (interactive)
  (chromel-open-new-url chromel-home-url))

(defun chromel-open-copied-url (&optional new-buffer)
  "Open the latest kill or clipboard text as an address or search.
With NEW-BUFFER, use a new selected browser buffer.  Follow Emacs clipboard
settings through `current-kill', just as `yank' does."
  (interactive "P")
  (let ((text (current-kill 0 t)))
    (when (string-empty-p (string-trim text)) (user-error "Copied text is empty"))
    (if new-buffer (chromel-open-new-url text) (chromel-open-url text))))

(defun chromel-open-copied-url-new-buffer ()
  "Open the copied address or search in a new selected browser buffer."
  (interactive)
  (chromel-open-copied-url t))

(defun chromel-next-tab (&optional count)
  "Select the browser COUNT places ahead in tab order, wrapping at the end."
  (interactive "p")
  (let* ((buffers (chromel--buffers))
         (index (cl-position (current-buffer) buffers)))
    (unless index (user-error "This is not a live Chromel buffer"))
    (chromel--select-buffer (nth (mod (+ index (or count 1)) (length buffers)) buffers))))

(defun chromel-previous-tab (&optional count)
  "Select the browser COUNT places back in tab order."
  (interactive "p")
  (chromel-next-tab (- (or count 1))))

(defun chromel-switch-tab ()
  "Choose a live browser buffer by title or address."
  (interactive)
  (let ((choices (mapcar (lambda (buffer)
                           (cons (format "%s  %s" (buffer-name buffer)
                                         (buffer-local-value 'chromel--url buffer)) buffer))
                         (chromel--buffers))))
    (unless choices (user-error "No live browser buffers"))
    (chromel--select-buffer (cdr (assoc (completing-read "Browser: " choices nil t) choices)))))

(defun chromel-last-tab ()
  "Select the most recently visited other live browser buffer."
  (interactive)
  (let* ((buffers (chromel--buffers))
         (previous (cl-find-if (lambda (buffer)
                                (and (not (eq buffer (current-buffer)))
                                     (memq buffer buffers)))
                              (buffer-list))))
    (unless previous (user-error "No previous browser buffer"))
    (chromel--select-buffer previous)))

(defun chromel-close-tab ()
  "Close this browser buffer and select the next one, if any."
  (interactive)
  (let* ((source (current-buffer))
         (buffers (chromel--buffers))
         (index (cl-position source buffers))
         (next (and index (> (length buffers) 1)
                    (nth (mod (1+ index) (length buffers)) buffers))))
    (unless index (user-error "This is not a live Chromel buffer"))
    (when (kill-buffer source)
      (when (and next (memq next (chromel--buffers))) (chromel--select-buffer next)))))

(defun chromel-reload () "Reload the current page." (interactive) (chromel--command "reload"))
(defun chromel-back () "Go back." (interactive) (chromel--command "back"))
(defun chromel-forward () "Go forward." (interactive) (chromel--command "forward"))
(defun chromel-stop () "Stop loading." (interactive) (chromel--command "stop"))
(defun chromel-focus () "Send keyboard focus to the page." (interactive) (chromel--command "focus"))
(defun chromel-devtools () "Open Chromium developer tools." (interactive) (chromel--command "devtools"))

(defun chromel-focus-parent-frame (&optional root)
  "Return scrolling to the parent of the currently focused iframe.
With prefix ROOT, return directly to the outermost page.  Keep Emacs
command focus so j/k operate on the new target."
  (interactive "P")
  (chromel--command "focus-parent" (if root "root" "parent"))
  (message "Chromel: returning to %s page" (if root "outermost" "parent")))

(defun chromel-focus-main-frame ()
  "Return scrolling to the outermost page, retaining command focus."
  (interactive)
  (chromel-focus-parent-frame t))

(defun chromel--scroll (steps &optional frame mode held)
  "Scroll STEPS in FRAME or the focused frame, using optional MODE.
HELD permits physical j/k hold tracking after the Emacs keymap chose scrolling."
  (unless (and (natnump chromel-scroll-step) (natnump chromel-scroll-duration)
               (natnump chromel-scroll-speed))
    (user-error "Scroll step, duration and speed must be nonnegative integers"))
  (chromel--command "scroll"
                (chromel--json (list :amount (if (or (null mode) (equal mode "pixels"))
                                             (* steps chromel-scroll-step) steps)
                                 :duration chromel-scroll-duration :speed chromel-scroll-speed
                                 :mode (or mode "pixels") :frame (or frame "")
                                 :held (if held t :false)))))

(defun chromel-scroll-down (&optional count)
  "Scroll the page down COUNT steps, keeping Emacs command focus.
Use the focused frame, including cross-origin iframes.  Scroll a focused
control's scrollable ancestor first, then that frame's page."
  (interactive "p")
  (chromel--scroll (or count 1) nil nil
               (and (called-interactively-p 'any) (not current-prefix-arg)
                    (equal (this-command-keys-vector) [106]))))

(defun chromel-scroll-up (&optional count)
  "Scroll the page up COUNT steps, keeping Emacs command focus."
  (interactive "p")
  (chromel--scroll (- (or count 1)) nil nil
               (and (called-interactively-p 'any) (not current-prefix-arg)
                    (equal (this-command-keys-vector) [107]))))

(defun chromel--json (object)
  "Serialize OBJECT as JSON text suitable for the native UTF-8 interface."
  (decode-coding-string (json-serialize object) 'utf-8-unix))

(defun chromel--eval (script)
  "Evaluate SCRIPT in this page and parse its JSON string result.
Only Emacs can initiate this request; no Lisp interface is exposed to pages."
  (unless chromel--id (user-error "This is not a live Chromel buffer"))
  (when chromel--eval-token (user-error "A page request is already pending"))
  (let ((deadline (+ (float-time) 5))
        (id chromel--id))
    (setq chromel--eval-token (format "chromel-js-%d" (cl-incf chromel--eval-counter))
          chromel--eval-reply nil)
    (unwind-protect
        (progn
          (chromel--command "eval" (chromel--json (list :token chromel--eval-token :script script)))
          (while (and (not chromel--eval-reply) (eql id chromel--id)
                      (< (float-time) deadline))
            (chromel--tick)
            (unless chromel--eval-reply (accept-process-output nil 0.01)))
          (unless chromel--eval-reply
            (user-error "Page did not respond; wait for it to load and retry (updated Helper requires restarting Emacs)"))
          (unless (eq t (plist-get chromel--eval-reply :ok))
            (user-error "Page: %s" (plist-get chromel--eval-reply :result)))
          (json-parse-string (plist-get chromel--eval-reply :result)
                             :object-type 'plist :array-type 'list))
      (setq chromel--eval-token nil chromel--eval-reply nil))))

(defun chromel--hint-script ()
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents (expand-file-name "native/hints.js" chromel--directory)))
    (buffer-string)))

(defun chromel--hint-call (session method &optional argument)
  "Call METHOD on the hint overlay belonging to SESSION."
  (format "JSON.stringify((()=>{const h=window.__emacsChromelHints;if(!h||h.session!==%s)return false;return h.%s(%s);})())"
          (chromel--json session) method (if argument (chromel--json argument) "")))

(defun chromel--read-hint (hints session)
  "Read a label from HINTS, narrowing the overlay for SESSION."
  (let ((prefix "") chosen)
    (while (not chosen)
      (let* ((event (read-key (format "Hint%s: %s  (C-g cancels)"
                                      (if (string-empty-p prefix) "" " label") prefix)))
             (next (cond ((memq event '(7 27 escape)) (keyboard-quit))
                         ((memq event '(127 8 backspace delete))
                          (substring prefix 0 (max 0 (1- (length prefix)))))
                         ((and (characterp event) (<= ?a event ?z))
                          (concat prefix (string event)))
                         (t prefix)))
             (matches (cl-remove-if-not
                       (lambda (hint) (string-prefix-p next (plist-get hint :label))) hints)))
        (when matches
          (setq prefix next)
          (unless (eq t (chromel--eval (chromel--hint-call session "filter" prefix)))
            (user-error "Page moved or changed; invoke hints again"))
          (setq chosen (cl-find prefix matches :key (lambda (hint) (plist-get hint :label))
                                :test #'equal)))))
    chosen))

(defun chromel--validate-hint-alphabet ()
  (unless (and (string-match-p "\\`[a-z]+\\'" chromel-hint-alphabet)
               (> (length chromel-hint-alphabet) 1)
               (= (length chromel-hint-alphabet) (length (delete-dups (string-to-list chromel-hint-alphabet)))))
    (user-error "chromel-hint-alphabet must contain at least two distinct lowercase letters")))

(defun chromel-follow (&optional new-buffer background)
  "Label visible interactive elements and activate one by typing its label.
Buttons are clicked and editable controls are focused.  With prefix
NEW-BUFFER, follow ordinary links in a new buffer.  With BACKGROUND as well,
leave the source selected.  C-g cancels."
  (interactive "P")
  (chromel--validate-hint-alphabet)
  (let ((source (current-buffer)) (id chromel--id)
        (session (format "hints-%d" (cl-incf chromel--eval-counter))) chosen)
    (chromel--command "unfocus")
    (unwind-protect
        (let ((hints (chromel--eval (format "%s(%s,%s)" (chromel--hint-script)
					(chromel--json chromel-hint-alphabet) (chromel--json session)))))
          (unless hints (user-error "No visible interactive elements on this page"))
          (setq chosen (chromel--read-hint hints session))
          (let ((action (chromel--eval (chromel--hint-call session "prepare" (plist-get chosen :label)))))
            (unless (and (listp action) (member (plist-get action :action) '("focus" "click")))
              (user-error "Element moved, was disabled or disappeared; invoke hints again"))
            (if (equal (plist-get action :action) "focus")
                (chromel-focus)
              (chromel--command "click" (chromel--json
                                     (list :x (plist-get action :x) :y (plist-get action :y)
                                           :newBuffer (if (and new-buffer (eq t (plist-get action :link)))
                                                          t :false)
                                           :background (if background t :false)))))))
      (when (buffer-live-p source)
        (with-current-buffer source
          (when (and chromel--id (eql chromel--id id))
            (ignore-errors
              (chromel--command "javascript" (chromel--hint-call session "clear")))))))))

(defun chromel-follow-new-buffer ()
  "Activate a hinted element; ordinary links open in a new selected buffer."
  (interactive)
  (chromel-follow t))

(defun chromel-follow-background ()
  "Activate a hinted element; ordinary links open in a background buffer."
  (interactive)
  (chromel-follow t t))

(defvar chromel-find-history nil)
(defvar chromel-find-minibuffer-map
  (let ((map (copy-keymap minibuffer-local-map)))
    (define-key map [escape] #'keyboard-quit)
    map))

(defun chromel-find-clear ()
  "Clear page search highlighting, retaining the last query for n/N."
  (interactive)
  (chromel--command "find-stop")
  (setq chromel--find-token nil chromel--find-reply nil chromel--find-active nil
        chromel--find-status "")
  (force-mode-line-update))

(defun chromel--find-run (text forward next)
  "Search for TEXT, moving FORWARD, continuing the search when NEXT."
  (when chromel--find-token (user-error "A search is already pending"))
  (chromel--command "unfocus")
  (let ((deadline (+ (float-time) 5)) (id chromel--id) complete)
    (setq chromel--find-token (format "find-%d" (cl-incf chromel--eval-counter))
          chromel--find-reply nil chromel--find-count 0 chromel--find-ordinal 0)
    (unwind-protect
        (progn
          (chromel--command "find" (chromel--json (list :text text :token chromel--find-token
						:forward (if forward t :false)
						:next (if next t :false))))
          (while (and (not chromel--find-reply) (eql id chromel--id) (< (float-time) deadline))
            (chromel--tick)
            (unless chromel--find-reply (accept-process-output nil 0.01)))
          (unless chromel--find-reply (user-error "Page search timed out; try again"))
          (setq chromel--find-text text chromel--find-active t complete t
                chromel--find-status (format "  Find %d/%d" chromel--find-ordinal chromel--find-count))
          (force-mode-line-update)
          (message "%s: %d/%d%s" text chromel--find-ordinal chromel--find-count
                   (if (zerop chromel--find-count) " (no matches)" "")))
      (setq chromel--find-token nil)
      (unless complete (when (eql id chromel--id) (chromel-find-clear))))))

(defun chromel-find (&optional text)
  "Find TEXT in the rendered page, or read it from the minibuffer.
Search is literal and case-insensitive.  RET searches; Esc/C-g cancels
and clears highlights.  Repeat with `chromel-find-next' or
`chromel-find-previous'."
  (interactive)
  (let (accepted)
    (unwind-protect
        (progn
          (unless text
            (chromel--command "unfocus")
            (setq text (read-from-minibuffer "Find in page: " nil chromel-find-minibuffer-map
                                             nil 'chromel-find-history chromel--find-text)))
          (if (string-empty-p text) (chromel-find-clear) (chromel--find-run text t nil))
          (setq accepted t))
      (unless accepted (chromel-find-clear)))))

(defun chromel-find-next ()
  "Select the next match of this buffer's last page search."
  (interactive)
  (if (string-empty-p chromel--find-text) (chromel-find)
    (chromel--find-run chromel--find-text t chromel--find-active)))

(defun chromel-find-previous ()
  "Select the previous match of this buffer's last page search."
  (interactive)
  (if (string-empty-p chromel--find-text) (chromel-find)
    (chromel--find-run chromel--find-text nil chromel--find-active)))

(defun chromel-scroll-half-page-down (&optional count)
  "Scroll COUNT half-viewports down in the active scrolling region."
  (interactive "p")
  (chromel--scroll (or count 1) nil "half"))

(defun chromel-scroll-half-page-up (&optional count)
  "Scroll COUNT half-viewports up in the active scrolling region."
  (interactive "p")
  (chromel--scroll (- (or count 1)) nil "half"))

(defun chromel-scroll-to-top ()
  "Scroll to the top of the active region, including iframes and dialogs."
  (interactive)
  (chromel--scroll -1 nil "top"))

(defun chromel-scroll-to-bottom ()
  "Scroll to the bottom of the active region, including iframes and dialogs."
  (interactive)
  (chromel--scroll 1 nil "bottom"))

(defun chromel-copy-url ()
  "Copy the current page URL using Emacs kill-ring/clipboard settings."
  (interactive)
  (unless chromel--id (user-error "This is not a live Chromel buffer"))
  (kill-new chromel--url)
  (message "Copied: %s" chromel--url))

(defun chromel--link-hints (multiple)
  "Copy a hinted link, or open links in background buffers when MULTIPLE."
  (chromel--validate-hint-alphabet)
  (let ((source (current-buffer)) (id chromel--id)
        (session (format "hints-%d" (cl-incf chromel--eval-counter)))
        (count 0))
    (chromel--command "unfocus")
    (unwind-protect
        (let ((hints (chromel--eval (format "%s(%s,%s,%s)" (chromel--hint-script)
					(chromel--json chromel-hint-alphabet) (chromel--json session)
					(chromel--json (if multiple "queue" "copy"))))))
          (unless hints (user-error "No visible links on this page"))
          (catch 'done
            (while t
              (let* ((chosen (chromel--read-hint hints session))
                     (link (chromel--eval (chromel--hint-call session "link" (plist-get chosen :label)))))
                (unless (and (listp link) (stringp (plist-get link :url)))
                  (user-error "Link moved or disappeared; invoke hints again"))
                (if multiple
                    (progn
                      (chromel--command "click" (chromel--json (list :x (plist-get link :x) :y (plist-get link :y)
                                                             :newBuffer t :background t)))
                      (cl-incf count)
                      (unless (eq t (chromel--eval (chromel--hint-call session "filter" "")))
                        (user-error "Page changed; invoke hints again"))
                      (message "Link sent to background (%d); choose another or Esc to finish" count))
                  (kill-new (plist-get link :url))
                  (message "Copied: %s" (plist-get link :url))
                  (throw 'done t))))))
      (when (buffer-live-p source)
        (with-current-buffer source
          (when (eql id chromel--id)
            (ignore-errors (chromel--command "javascript" (chromel--hint-call session "clear")))))))))

(defun chromel-copy-link ()
  "Select a link by hint and copy its current URL without clicking it."
  (interactive)
  (chromel--link-hints nil))

(defun chromel-follow-multiple ()
  "Repeatedly select links to open in background buffers; Esc/C-g finishes.
Keep the source selected.  Use ordinary HTTP, HTTPS or file links; site
click handlers can still prevent navigation.  Hint labels remain stable."
  (interactive)
  (condition-case nil (chromel--link-hints t)
    (quit (message "Finished opening links"))))

(defun chromel--session-read (file)
  "Read and validate FILE without evaluating any Lisp.  Signal on bad data."
  (let* ((coding-system-for-read 'utf-8-unix)
         (data (with-temp-buffer
                 (insert-file-contents file)
                 (json-parse-buffer :object-type 'plist :array-type 'array)))
         (tabs (plist-get data :tabs))
         (closed (plist-get data :closed))
         (selected (plist-get data :selected)))
    (unless (and (listp data) (eql (plist-get data :version) 1)
                 (vectorp tabs) (vectorp closed) (natnump selected)
                 (< selected (max 1 (length tabs)))
                 (cl-every (lambda (entry)
                             (and (listp entry) (stringp (plist-get entry :url))
                                  (not (string-empty-p (plist-get entry :url)))
                                  (stringp (plist-get entry :title))))
                           (append tabs closed nil))
                 (cl-every (lambda (entry) (natnump (plist-get entry :index))) closed))
      (error "Invalid or unsupported Chromel session: %s" file))
    data))

(defun chromel--session-load ()
  "Capture the previous run before the first page can overwrite its session."
  (unless chromel--session-loaded
    (condition-case err
        (let ((file (expand-file-name "session.json" chromel-data-directory)))
          (when (file-exists-p file)
            (setq chromel--previous-session (chromel--session-read file)
                  chromel--closed-tabs (seq-take (append (plist-get chromel--previous-session :closed) nil)
                                             chromel-closed-tab-limit)))
          (setq chromel--session-loaded t))
      (error
       ;; Do not silently replace corrupt, unreadable or newer-format data.
       (setq chromel--session-loaded 'failed)
       (message "Chromel session preserved without overwriting: %s" (error-message-string err))))))

(defun chromel--session-snapshot ()
  "Return a versioned snapshot including deferred pages and closed-page history."
  (let* ((buffers (chromel--buffers))
         (selected (window-buffer (selected-window)))
         (index (or (cl-position selected buffers)
                    (cl-position chromel--last-selected-tab buffers) 0)))
    (list :version 1 :selected index
          :tabs (vconcat (mapcar (lambda (buffer)
                                  (with-current-buffer buffer
                                    (list :url chromel--url :title chromel--title))) buffers))
          :closed (vconcat chromel--closed-tabs))))

(defun chromel--session-write (name data)
  "Atomically write DATA as UTF-8 JSON to NAME in `chromel-data-directory'."
  (make-directory chromel-data-directory t)
  (set-file-modes chromel-data-directory #o700)
  (let ((temp (make-temp-file (expand-file-name ".session-" chromel-data-directory))))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (with-temp-file temp
              (set-buffer-multibyte nil)
              (insert (json-serialize data))))
          (set-file-modes temp #o600)
          (rename-file temp (expand-file-name name chromel-data-directory) t))
      (when (file-exists-p temp) (delete-file temp)))))

(defun chromel-save-session ()
  "Save current tabs, selected page and closed-page history to session.json.
URLs and titles are saved, not page contents, form input or navigation stacks."
  (interactive)
  (chromel--session-load)
  (unless (eq chromel--session-loaded t)
    (user-error "Session file could not be read; preserving it without overwriting"))
  (unless (or chromel--session-active (chromel--buffers))
    (user-error "No current browser session to save"))
  (unless chromel--session-backed-up
    (when chromel--previous-session
      (chromel--session-write "session.previous.json" chromel--previous-session))
    (setq chromel--session-backed-up t))
  (chromel--session-write "session.json" (chromel--session-snapshot))
  (setq chromel--session-dirty nil)
  (when (timerp chromel--session-timer) (cancel-timer chromel--session-timer))
  (setq chromel--session-timer nil)
  (when (called-interactively-p 'interactive) (message "Chromel session saved")))

(defun chromel--session-save-quietly ()
  (setq chromel--session-timer nil)
  (when (and chromel-session-auto-save (eq chromel--session-loaded t) chromel--session-active)
    (condition-case err
        (chromel-save-session)
      (error (message "Chromel session save failed: %s" (error-message-string err))))))

(defun chromel--session-changed ()
  "Coalesce changes into a save within one second, without waiting for idle."
  (unless (or chromel--session-inhibit chromel--shutting-down)
    (setq chromel--session-active t chromel--session-dirty t)
    (when (and chromel-session-auto-save (eq chromel--session-loaded t)
               (not (timerp chromel--session-timer)))
      (setq chromel--session-timer (run-at-time 1 nil #'chromel--session-save-quietly)))))

(defun chromel-reopen-closed-tab ()
  "Restore the latest closed page at its former tab position and select it.
Also works after C-x k, and from another buffer when the last page was closed."
  (interactive)
  (chromel--session-load)
  (unless chromel--closed-tabs (user-error "No closed browser pages to restore"))
  (let ((entry (car chromel--closed-tabs)) buffer)
    (let ((chromel--session-inhibit t))
      (condition-case err
          (progn
            (setq buffer (chromel--make-tab (plist-get entry :url) (plist-get entry :title)
                                        (plist-get entry :index)))
            (chromel--select-buffer buffer))
        ((error quit)
         (when (buffer-live-p buffer) (kill-buffer buffer))
         (signal (car err) (cdr err)))))
    ;; Consume only after successful activation; a failed X remains retryable.
    (pop chromel--closed-tabs)
    (chromel--session-changed)
    buffer))

(defun chromel-restore-session ()
  "Restore the previous run's pages once, keeping current pages intact.
Append restored pages in saved order and select the saved current page.
Only that page creates a browser; other pages load when first selected."
  (interactive)
  (chromel--session-load)
  (unless (eq chromel--session-loaded t) (user-error "Cannot restore unreadable session.json"))
  (when chromel--session-restored (user-error "Previous session has already been restored"))
  (let ((entries (plist-get chromel--previous-session :tabs))
        (selected (plist-get chromel--previous-session :selected))
        (original (window-buffer (selected-window))) buffers)
    (unless (> (length entries) 0) (user-error "No saved browser pages to restore"))
    (let ((chromel--session-inhibit t))
      (condition-case err
          (progn
            (mapc (lambda (entry)
                    (push (chromel--make-tab (plist-get entry :url) (plist-get entry :title)) buffers))
                  entries)
            (setq buffers (nreverse buffers))
            (chromel--select-buffer (nth selected buffers)))
        ((error quit)
         (dolist (buffer buffers) (when (buffer-live-p buffer) (kill-buffer buffer)))
         (when (buffer-live-p original) (switch-to-buffer original))
         (signal (car err) (cdr err)))))
    (setq chromel--session-restored t)
    (chromel--session-changed)
    (message "Restored %d pages; background pages load when selected" (length buffers))
    buffers))

(defun chromel--history-load ()
  (unless chromel--history-loaded
    (setq chromel--history-loaded t)
    (let ((file (expand-file-name "history.json" chromel-data-directory))
          (coding-system-for-read 'utf-8-unix))
      (when (file-readable-p file)
        (condition-case err
            (with-temp-buffer
              (insert-file-contents file)
              (setq chromel--history
                    (cl-remove-if-not
                     (lambda (item) (and (stringp (plist-get item :url))
                                         (stringp (plist-get item :title))))
                     (json-parse-buffer :object-type 'plist :array-type 'list))))
          (error
           (setq chromel--history-loaded nil)
           (message "Chromel history: %s" (error-message-string err))))))))

(defun chromel--history-record (url title)
  (when (and (> chromel-history-limit 0) (string-match-p "\\`https?://" url))
    (setq chromel--history
          (cons (list :url url :title title :time (float-time))
                (cl-remove url chromel--history :key (lambda (x) (plist-get x :url))
                           :test #'equal)))
    (when (> (length chromel--history) chromel-history-limit)
      (setcdr (nthcdr (1- chromel-history-limit) chromel--history) nil))
    (unless (timerp chromel--history-timer)
      (setq chromel--history-timer (run-with-idle-timer 1 nil #'chromel--history-save)))))

(defun chromel--history-save ()
  (setq chromel--history-timer nil)
  (when chromel--history-loaded
    (make-directory chromel-data-directory t)
    (let ((temp (make-temp-file (expand-file-name ".history-" chromel-data-directory))))
      (unwind-protect
          (progn
            ;; `json-serialize' already returns UTF-8 bytes.  Keep them in
            ;; a unibyte buffer so Emacs does not ask how to encode raw bytes
            ;; inserted into a multibyte text buffer (e.g. Chinese titles).
            (let ((coding-system-for-write 'no-conversion))
              (with-temp-file temp
                (set-buffer-multibyte nil)
                (insert (json-serialize (vconcat chromel--history)))))
            (set-file-modes temp #o600)
            (rename-file temp (expand-file-name "history.json" chromel-data-directory) t))
        (when (file-exists-p temp) (delete-file temp))))))

(defun chromel-history ()
  "Choose and open a previously visited URL."
  (interactive)
  (chromel--history-load)
  (unless chromel--history (user-error "Browser history is empty"))
  (let* ((choices (mapcar (lambda (item)
                            (cons (format "%s  %s" (plist-get item :title)
                                          (plist-get item :url))
                                  (plist-get item :url))) chromel--history))
         (url (cdr (assoc (completing-read "History: " choices nil t) choices))))
    (if (memq (current-buffer) (chromel--buffers)) (chromel-open-url url) (chromel url))))

(defun chromel-diagnostics ()
  "Display native browser state and paths for troubleshooting."
  (interactive)
  (let ((page-info (when chromel--id (chromel--native-inspect chromel--id))))
    (with-help-window "*Chromel diagnostics*"
      (princ (format "Emacs: %s\nModule: %s\nRuntime: %s\nData: %s\nPump: %s\n\n%s\n"
                     emacs-version chromel-native-module chromel-runtime-directory chromel-data-directory
                     (if chromel--timer "running" "stopped")
                     (if chromel--initialized (chromel--native-info) "Not initialized")))
      (when page-info (princ (concat "\nCurrent view: " page-info "\n"))))))

;; Refresh existing browser headers when this file is loaded again.
(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (when (derived-mode-p 'chromel-mode)
      (setq-local header-line-format chromel--header-line-format))))
(force-mode-line-update t)

(when (chromel--buffers)
  (setq chromel--tabs (chromel--buffers))
  (chromel--session-load)
  (chromel--session-changed))

(provide 'chromel)
;;; chromel.el ends here
