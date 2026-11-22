;;; gui-scroll.el --- Focused iframe and smooth scroll regression -*- lexical-binding: t; -*-
(require 'chromel)
(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))
(defvar chromel-test--source nil)
(defvar chromel-test--busy nil)
(defvar chromel-test--phase 'loading)
(defvar chromel-test--deadline (+ (float-time) 40))

(defun chromel-test--assert (value description)
  (unless value (error "%s" description)))
(defun chromel-test--js (expression)
  (chromel--eval (concat "JSON.stringify(" expression ")")))
(defun chromel-test--until (expression description)
  (let ((deadline (+ (float-time) 4)) done)
    (while (and (not done) (< (float-time) deadline))
      (setq done (eq t (chromel-test--js expression)))
      (unless done (accept-process-output nil 0.01)))
    (chromel-test--assert done description)))
(defun chromel-test--finish (success description)
  (with-temp-file (getenv "CHROMEL_TEST_RESULT")
    (insert (if success "PASS: " "FAIL: ") description "\n"))
  (kill-emacs (if success 0 1)))
(defun chromel-test--focus (id x y)
  (chromel-focus)
  (chromel--command "click" (chromel--json (list :x x :y y :newBuffer :false)))
  (chromel-test--until (format "frameState.%s?.focused" id) (concat "Frame did not receive click: " id))
  ;; Same release path used by C-g before pressing j/k in command mode.
  (chromel--command "unfocus"))

(defun chromel-test--frame (name)
  (let ((deadline (+ (float-time) 3)) done)
    (while (and (not done) (< (float-time) deadline))
      (chromel--tick)
      (setq done (equal name (plist-get (json-parse-string (chromel--native-inspect chromel--id) :object-type 'plist)
                                       :focusedFrameName)))
      (unless done (accept-process-output nil 0.01)))
    (chromel-test--assert done (concat "Did not focus frame: " name))
    (chromel-test--assert
     (eq :false (plist-get (json-parse-string (chromel--native-inspect chromel--id) :object-type 'plist) :focused))
     "Returning to parent stole Emacs command focus")))

(defun chromel-test--scroll-frames ()
  (let ((chromel-scroll-step 60) (chromel-scroll-duration 200))
    (dolist (entry '(("same" 80 80) ("cross" 380 80)))
      (apply #'chromel-test--focus entry)
      ;; Keep native page focus and send an actual Cocoa key, as a user does
      ;; immediately after clicking into an embedded page.  No C-g first.
      (chromel-focus)
      (chromel--command "test-key" "j")
      (chromel-test--until (format "frameState.%s.y===60 && scrollY===0" (car entry))
                       "j did not scroll the focused iframe independently")
      (unless (eq t (chromel-test--js "matchMedia('(prefers-reduced-motion: reduce)').matches"))
        (chromel-test--assert (eq t (chromel-test--js (format "frameState.%s.samples.some(y=>y>0&&y<60)" (car entry))))
                          "Scroll jumped without intermediate animation frames"))
      (let ((current-prefix-arg 3)) (call-interactively (key-binding (kbd "j"))))
      (chromel-scroll-down)
      (chromel-scroll-down)
      (chromel-test--until (format "frameState.%s.y===360" (car entry)) "Repeated scroll distance was lost")
      (chromel-scroll-up 5)
      (chromel-test--until (format "frameState.%s.y===60" (car entry)) "Iframe did not prepare for actual k key")
      (chromel--command "test-key" "k")
      (chromel-test--until (format "frameState.%s.y===0" (car entry)) "k did not scroll the iframe up"))
    ;; Two frame boundaries, crossing origins in both directions.
    (chromel-test--focus "nested" 380 140)
    (chromel-scroll-down 2)
    (chromel-test--until "frameState.nested.y===120 && frameState.cross.y===0 && frameState.same.y===0 && scrollY===0"
                     "Nested frame scroll affected its ancestors")
    (chromel-test--assert
     (eq :false (plist-get (json-parse-string (chromel--native-inspect chromel--id) :object-type 'plist) :focused))
     "Frame scrolling stole Emacs command focus")
    ;; Return one layer using the actual key binding, without clicking outside.
    (call-interactively (key-binding (kbd "C-c C-p")))
    (chromel-test--frame "cross")
    (chromel-scroll-down)
    (chromel-test--until "frameState.cross.y===60 && frameState.nested.y===120 && scrollY===0"
                     "Parent command did not redirect scrolling by one layer")
    ;; Re-enter the inner frame, then jump directly to the outermost page.
    (chromel-test--focus "nested" 380 140)
    (chromel-test--frame "nested")
    (let ((current-prefix-arg '(4))) (call-interactively (key-binding (kbd "C-c C-p"))))
    (chromel-test--frame "")
    (chromel-scroll-down)
    (chromel-test--until "scrollY===60 && frameState.nested.y===120" "Parent frame routing did not recover")
    ;; Calling parent on the top-level page is harmless.
    (chromel-focus-parent-frame)
    (chromel-test--frame "")
    (let ((chromel-scroll-duration 600))
      (chromel-scroll-down 2)
      (chromel-test--until "scrollY>60" "Smooth scroll did not begin")
      (chromel-scroll-up 6)
      (chromel-test--until "scrollY===0" "Direction reversal retained the old target")
      (chromel-scroll-down 10)
      (chromel-test--until "scrollY>0" "Cancellation test did not start")
      (let ((position (chromel-test--js "(dispatchEvent(new WheelEvent('wheel')),scrollY)")))
        (accept-process-output nil 0.2)
        (chromel-test--assert (= position (chromel-test--js "scrollY")) "Wheel input did not cancel animation")))
    (let* ((position (chromel-test--js "scrollY")) (chromel-scroll-duration 0))
      (chromel-scroll-down 2)
      (chromel-test--until (format "scrollY===%s" (+ position 120)) "Instant mode failed"))))

(defun chromel-test--step ()
  (unless chromel-test--busy
    (let ((chromel-test--busy t))
      (with-current-buffer (if (buffer-live-p chromel-test--source) chromel-test--source (current-buffer))
        (condition-case err
            (progn
              (when (> (float-time) chromel-test--deadline) (error "Scroll test timed out"))
              (pcase chromel-test--phase
                ('loading
                 (when (equal chromel--title "scroll-ready")
                   (switch-to-buffer chromel-test--source)
                   (delete-other-windows)
                   (chromel--sync)
                   (chromel-test--until "Boolean(frameState.same && frameState.cross && frameState.nested)" "Frame fixtures did not load")
                   (chromel-test--scroll-frames)
                   (kill-buffer chromel-test--source)
                   (setq chromel-test--phase 'closing)))
                ('closing
                 (when (string-match-p "Browsers including DevTools: 0" (chromel--native-info))
                   (chromel-test--finish t "Scrolling: same/cross-origin nested focus, keyboard parent/root return through the browser keymap, smooth samples, repeated distance, reversal, wheel cancellation, instant mode")))))
          (error (chromel-test--finish nil (error-message-string err))))))))

(run-at-time 1 nil
             (lambda ()
               (condition-case err
                   (progn
                     (set-frame-size nil 1100 750 t)
                     (setq chromel-test--source (chromel (getenv "CHROMEL_TEST_URL")))
                     (run-at-time 0.2 0.2 #'chromel-test--step))
                 (error (chromel-test--finish nil (error-message-string err))))))
