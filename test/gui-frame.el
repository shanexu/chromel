;;; gui-frame.el --- pin the frame size every GUI test runs in -*- lexical-binding: t; -*-
;; Geometry assertions in these scripts were written against one frame size.
;; The default depends on the display and the user's font, and a short window
;; hides links, which changes both hint labels and click targets.  Pin it once
;; here (scripts/test-gui.py loads it before the script) instead
;; of letting each script guess.

(set-frame-size nil 1100 750 t)

(provide 'gui-frame)
;;; gui-frame.el ends here
