;;; gui-resize.el --- the viewport follows the Emacs window -*- lexical-binding: t; -*-
(require 'chromel)
(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))
(defvar chromel-test--buffer nil)
(defvar chromel-test--origin nil)
(defconst chromel-test--width-script "JSON.stringify(window.innerWidth)")
(defun chromel-test--assert (value text) (unless value (error "%s" text)))
(defun chromel-test--finish (ok text)
  (let ((path (getenv "CHROMEL_TEST_RESULT")))
    (when path
      (with-temp-file path (insert (if ok "PASS: " "FAIL: ") text "\n")))
    (princ (concat (if ok "PASS: " "FAIL: ") text "\n") #'external-debugging-output)
    (kill-emacs (if ok 0 1))))
(defun chromel-test--width ()
  (and (buffer-live-p chromel-test--buffer)
       (with-current-buffer chromel-test--buffer
         (ignore-errors (chromel--eval chromel-test--width-script)))))
(defun chromel-test--until (predicate text seconds)
  (let ((deadline (+ (float-time) seconds)) done)
    (while (and (not done) (< (float-time) deadline))
      (setq done (funcall predicate))
      (unless done (accept-process-output nil 0.01)))
    (chromel-test--assert done (format "%s; width=%S" text (chromel-test--width)))))
(defun chromel-test--title-p (expected)
  (lambda ()
    (and (buffer-live-p chromel-test--buffer)
         (equal (buffer-local-value 'chromel--title chromel-test--buffer) expected))))
(defun chromel-test--view-width ()
  "Pixel width of the window that shows the chromel buffer."
  (let* ((window (get-buffer-window chromel-test--buffer t))
         (edges (window-inside-pixel-edges window)))
    (- (nth 2 edges) (nth 0 edges))))
(defun chromel-test--matches-view-p (width view)
  (and (numberp width) (<= (abs (- width view)) 2)))
(defun chromel-test--run ()
  (condition-case error
      (let ((chromel-focus-on-open nil))
        (setq chromel-test--origin (string-remove-suffix "/resize" (getenv "CHROMEL_TEST_URL")))
        (setq chromel-test--buffer (chromel (concat chromel-test--origin "/resize")))
        (chromel-test--until (chromel-test--title-p "resize-fixture")
                             "The resize fixture did not load" 25)
        (let ((before (chromel-test--width)))
          (chromel-test--assert (and (numberp before) (> before 0))
                                (format "The page never had a viewport: %S" before))
          ;; Split, then resize the window inside the frame.  The frame itself
          ;; never changes size, which is the case the issue reports.
          (split-window-right)
          (let* ((window (get-buffer-window chromel-test--buffer t))
                 (other (next-window window))
                 (split-width (chromel-test--width))
                 ;; Resize while another window is selected: the preview is
                 ;; usually not the selected window when this happens.
                 (view (progn (select-window other)
                              (window-resize window -150 t nil t)
                              (chromel-test--view-width))))
            (chromel-test--until
             (lambda () (chromel-test--matches-view-p (chromel-test--width) view))
             "The page viewport did not follow the window" 15)
            (chromel-test--assert
             (> (abs (- split-width (chromel-test--width))) 0)
             "resizing the window did not change the viewport"))
          ;; A tab created while the window is already narrow must be born at
          ;; the right size, not at the 1x1 placeholder size.
          (setq chromel-test--buffer (chromel (concat chromel-test--origin "/resize")))
          (chromel-test--until (chromel-test--title-p "resize-fixture")
                               "The second tab did not load" 25)
          (let ((view (chromel-test--view-width)))
            (chromel-test--until
             (lambda () (chromel-test--matches-view-p (chromel-test--width) view))
             "A new tab kept the placeholder size" 10)))
        (chromel-test--finish t "the viewport follows the window, for old and new tabs"))
    (error (chromel-test--finish nil (error-message-string error)))))
(run-at-time 1 nil #'chromel-test--run)
