;; elastindent-mode  --- fix indentation with variable-pitch fonts. -*- lexical-binding: t; -*-
;; Copyright (C) 2023 Jean-Philippe Bernardy
;; Copyright (C) 2021 Scott Messick (tenbillionwords)

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;; General terminological note: elastindent-mode is concerned with
;;; adjusting the width of only spaces and tabs which occur before a
;;; printing character (not space or tab) on a line.  We use the word
;;; “indentation” to refer to these tabs or spaces.  It is ambiguous
;;; whether Unicode space characters other than space and (horizontal)
;;; tab should be considered part of the leading space or not, but in
;;; the code we assume it is only spaces and tabs.  Thus
;;; elastindent-mode treats other space characters as printing
;;; characters.
;;; The support for tabs is currently limited.  Tabs can only be first
;;; in the indentation (they cannot follows spaces).  Editting code
;;; with tabs isn't fully supported either.

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'qosmetic)

(defun elastindent-mode-maybe ()
  "Function to put in hooks, for example `prog-mode-hook'."
  ;; See org-src-font-lock-fontify-block for buffer name.  Elastindent
  ;; isn't needed in fontification buffers. Fontification is called on
  ;; every keystroke (‽). Calling elastindent-do-buffer on each
  ;; keystroke on the whole block is very slow.
  (unless (string-prefix-p " *org-src-fontification:" (buffer-name))
    (elastindent-mode)))

(defgroup elastindent nil "Customization of elastic indentation."
  :group 'elastic)

(defcustom elastindent-lvl-cycle-size 1 "Size of the cycle used for faces.
If N is the cycle size, then faces 0 to N-1 will be used. See
also `elastindent-fst-col-faces' and `elastindent-rest-faces'."
  :type 'int :group 'elastindent)

(defcustom elastindent-fontify t
  "If t, fontify indent levels.
Fontification can only happen on a per-character basis.
Therefore, if indentation is implemented by a mix of space and
tabulation characters, as typical in Emacs source code, the
results will not be pretty."
  :type 'bool :group 'elastindent)

(defface elastindent '((t (:inherit lazy-highlight))) "Face for indentation highlighting.")
(defface elastindent-2 '((t (:inherit highlight))) "Second face for indentation highlighting.")

(defcustom elastindent-fst-col-faces '(elastindent)
  "Faces for various levels (First column)." :type '(list face) :group 'elastindent)

(defcustom elastindent-rest-faces '(nil)
  "Faces for various levels (First column)."
  :type '(list face)
  :group 'elastindent)

(defface elastindent-vertical-lines '((t (:box (:line-width (-1 . 0))))) "Face for indentation lines.")

(defun elastindent-fontify-alternate ()
  "Highlight indentation by columns of alternating background color."
  (interactive)
  (setq elastindent-lvl-cycle-size 2)
  (setq elastindent-rest-faces '(elastindent elastindent-2))
  (setq elastindent-fst-col-faces '(elastindent elastindent-2)))

(defun elastindent-fontify-with-lines ()
  "Experimental way to fontify indentation."
  (interactive)
  (setq elastindent-lvl-cycle-size 2)
  (setq elastindent-rest-faces '(elastindent-vertical-lines default))
  (setq elastindent-fst-col-faces '(elastindent-vertical-lines default)))

(define-minor-mode elastindent-mode
  "Improves indentation with in variable-pitch face.
Adjust the width of indentation characters to align the indented
code to the correct position.  The correct position is defined as
the same relative position to the previous line as it were if a
fixed-pitch face was used.

More precisely, any space character on a line with no printing
characters before it will be matched up with a corresponding
character on the previous line, if there is one.  That character
may itself be a width-adjusted space, meaning the width
ultimately comes from some other kind of character higher up.

Due to technical limitations, this mode does not try to detect
situations where the font has changed but the text hasn't, which
will mess up the alignment.  You can put
‘elastindent-do-buffer-if-enabled’ in appropriate hooks to mitigate the problem."
  :init-value nil :lighter nil :global nil
  (if elastindent-mode
      (progn
        ;; (message "activating elastindent in %s" (buffer-name))
        (elastindent-do-buffer)
        (qosmetic-add-handler 'elastindent-do-region 50)
        (add-hook 'text-scale-mode-hook 'elastindent-do-buffer nil t))
    (progn
      (qosmetic-remove-handler 'elastindent-do-region)
      (elastindent-clear-buffer))))

(defun elastindent-char-lvl (pos l-pos)
  "Return the indentation level at POS.
An indentation level is not the colum, but rather defined as the
number of times an indentation occured.  Level is negative for the
spaces which aren't in the first column of any given level.  If
this cannot be determined locally by what happens at POS, then
look at L-POS, which is a position just to the left of the
position for which we want the level."
  (or (get-text-property pos 'elastindent-lvl)
      (if (or (eq pos (point-min)) (eq (char-after (1- pos)) ?\n))
          1 ;; first char in the line. creates an indentation level by default.
        (let ((lvl-before (get-text-property (1- pos) 'elastindent-lvl)))
          (if (and lvl-before (<= lvl-before 0))
              ;; it's a space before this position. Thus this character creates a new indentation level.
              (1+ (abs lvl-before))
            (- (abs (or (get-text-property l-pos 'elastindent-lvl) 0)))))))) ; in case of tabs we have to come up with some number. Use 0.

(defun elastindent-set-char-pixel-width (pos w)
  "Set the width of character at POS to be W.
This only works if the character in question is a space or a tab.
Also add text properties to remember that we did this change and
by what."
  (if w (add-text-properties pos (1+ pos)
                             (list 'display (list 'space :width (list w))
                                   'elastindent-adjusted t
                                   'elastindent-width w))
    (remove-text-properties pos (1+ pos) '(display elastindent-width elastindent-adjusted))))

(defun elastindent-avg-info (lst)
  "Return the combination of infos in LST."
  (cons (-sum (-map 'car lst)) (-some 'cdr lst)))

(defun elastindent-set-char-info (pos i)
  "Set width and face I for space at POS.
The car of I is the width, and the cdr of I is the level."
  (when i
    (elastindent-set-char-pixel-width pos (car i))
    (let* ((lvl (or (cdr i)))
           (face-set (if (> lvl 0) elastindent-fst-col-faces elastindent-rest-faces))
           (face (nth (mod lvl elastindent-lvl-cycle-size) face-set)))
      (put-text-property pos (1+ pos) 'elastindent-lvl lvl)
      (when (and elastindent-fontify lvl)
        (if face (put-text-property pos (1+ pos) 'font-lock-face face)
          (remove-text-properties  pos (1+ pos) '(font-lock-face)))))))

(defun elastindent-column-leaves-indent (target)
  "Return t if by advancing TARGET columns one reaches the end of the indentation."
  (let ((col 0))
    (while (and (not (eobp)) (< col target))
      (pcase (char-after)
        (?\s (setq col (1+ col)))
        (?\t (setq col (+ 8 col)))
        (_ (setq target -1)))
      (when (<= 0 target) (forward-char)))
    (not (looking-at (rx (any "\s\t"))))))

(defun elastindent-in-indent ()
  "Return t iff all characters to the left are indentation chars."
  (save-excursion
    (while (and (not (bolp))
                (pcase (char-before)
                  ((or ?\s ?\t) (or (backward-char 1) t)))))
    (bolp)))

(defun elastindent-do-1 (force-propagate start-col change-end)
  "Adjust width of indentations.
This is in response to a change starting at point and ending at
CHANGE-END.  START-COL is the minimum column where a change
occured.  Start at point and continue until line which cannot be
impacted by the change is found.  Such a line occurs if its
indentation level is less than START-COL and starts after
CHANGE-END.

Thus a large value of START-COL means that little work needs to
be done by this function.  This optimisation is important,
because otherwise one needs to find a line with zero indentation,
which can be much further down the buffer.

If a change spans several lines, then START-COL is ignored, and
changes are propagated until indentation level reaches 0.
FORCE-PROPAGATE forces even single-line changes to be treated
this way."
  (let (prev-widths ; the list of widths of each *column* of indentation of the previous line
        (reference-pos 0) ; the buffer position in the previous line of 1st printable char
        space-widths) ; accumulated widths of columns for current line
    ;; (message "elastindent-do: %s [%s, %s]" start-col (point) change-end)
    (cl-flet*
        ((get-next-column-width () ; find reference width in the previous line. (effectful)
           (let* ((l-pos (1- (point)))
                  (w (if prev-widths (pop prev-widths) ; we have a cached width: use it.
                       (if (eql (char-after reference-pos) ?\n) ; we're at the end of the reference line.
                           (cons nil (if (bolp)
                                         (- 1) ; we're at a space on the 1st column with an empty line above. No indentation here.
                                       (- (abs (elastindent-char-lvl l-pos nil))))) ; leave width as is. Level is the same as char on the left; but not 1st column.
                         (prog1
                             (cons (qosmetic-char-pixel-width reference-pos) (elastindent-char-lvl reference-pos l-pos))
                           (setq reference-pos (1+ reference-pos)))))))
             (push w space-widths) ; cache width for next line
             ;; (message "char copy: %s->%s (w=%s) %s" (1- reference-pos) (point) w prev-widths)
             w))
         (char-loop () ; take care of one line.
           ;; copy width from prev-widths, then reference-pos to (point). Loop to end of indentation.
           ;; Preconditions: cur col = start-col.  prev-widths=nil or contains cached widths
           ;; (message "@%s %s=>%s %s" (line-number-at-pos) (- reference-pos (length prev-widths)) (point) prev-widths)
           (while-let ((cur-line-not-ended-c (not (eolp)))
                       (char (char-after))
                       (char-is-indent-c (or (eql char ?\s) (eql char ?\t))))
             (pcase char
               (?\s (elastindent-set-char-info (point) (get-next-column-width)))
               (?\t (elastindent-set-char-info (point)
                                               (elastindent-avg-info
                                                (--map (get-next-column-width) (-repeat tab-width ()))))))
             (forward-char)))
         (next-line () ; advance to next line, maintaining state.
           (setq prev-widths (nreverse space-widths))
           (setq space-widths nil)
           (setq reference-pos (point)) ; we go to next line exactly after we reached the last space
           (forward-line)))
      (save-excursion
        (when (eq (forward-line -1) 0)
          (setq reference-pos (progn (move-to-column start-col) (point)))))
      ;; (message "%s: first line. update from startcol=%s curcol=%s" (line-number-at-pos) start-col (current-column))
      (when (elastindent-in-indent) ; if not characters are not to be changed.
        (char-loop))
      (next-line)
      (when (or force-propagate (< (point) change-end))
        ;; (message "%s: main phase; update lines from col 0" (line-number-at-pos))
        (when (> start-col 0)  ; reference is wrong now
          (setq start-col 0)
          (setq prev-widths nil)
          (setq reference-pos (save-excursion (forward-line -1) (point))))
        (while (< (point) change-end)
          (char-loop)
          (next-line)))
      ;; (message "%s: propagate changes and stop if indentation is too small" (line-number-at-pos))
      (while (not (elastindent-column-leaves-indent start-col))
        (char-loop)
        (next-line))
      ;; (message "%s: propagation complete" (line-number-at-pos))
      (beginning-of-line)))) ; we did not in fact propagate on this line yet.

(defun elastindent-change-extend (end)
  "Return the first position after END which does not contain a space."
  (max (point)
       (save-excursion
         (goto-char end)
         ;; if we are changing something then the spaces just after the changes are
         ;; invalid and must be updated.
         (search-forward-regexp "[^\t\s]" nil t)
         (1- (point)))))

(defun elastindent-do-region (force-propagate start end)
  "Adjust width of indentation characters in given region and propagate.
The region is between START and END in current
buffer.  Propagation means to also fix the indentation of the
lines which follow, if their indentation widths might be impacted
by changes in given region.  See `elastindent-do' for the
explanation of FORCE-PROPAGATE."
  ;; (message "edr: (%s) %s-%s" force-propagate start end)
  (let ((e (elastindent-change-extend end)))
    (elastindent-clear-region start e)
    (goto-char start)
    (elastindent-do-1 force-propagate (current-column) e)))

(defun elastindent-do-buffer ()
  "Adjust width of all indentation spaces and tabs in current buffer."
  (interactive)
  (qosmetic-with-context
    (elastindent-do-region nil (point-min) (point-max))))

(defun elastindent-do-buffer-if-enabled ()
  "Call `elastindent-do-buffer' if `elastindent-mode' is enabled."
  (when elastindent-mode (elastindent-do-buffer)))

(defun elastindent-clear-region (start end)
  "Remove all `elastindent-mode' properties between START and END."
  (interactive "r")
  (qosmetic-clear-region-properties
   start end 'elastindent-adjusted '(elastindent-adjusted
                                     elastindent-width
                                     elastindent-lvl
                                     display
                                     font-lock-face
                                     mouse-face)))

(defun elastindent-clear-buffer ()
  "Remove all `elastindent-mode' properties in buffer."
  (interactive)
  (elastindent-clear-region (point-min) (point-max)))

(provide 'elastindent)
;;; elastindent.el ends here
