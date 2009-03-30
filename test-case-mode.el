;;; test-case-mode.el --- unit test front-end
;;
;; Copyright (C) 2009 Nikolaj Schumacher
;;
;; Author: Nikolaj Schumacher <bugs * nschum de>
;; Version: 
;; Keywords: tools
;; URL: http://nschum.de/src/emacs/test-case-mode/
;; Compatibility: GNU Emacs 22.x, GNU Emacs 23.x
;; Package-Requires: ((fringe-helper "0.1.1"))
;;
;; This file is NOT part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 2
;; of the License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;; `test-case-mode' is a minor mode for running unit tests.  It is extensible
;; and currently comes with back-ends for JUnit, CxxTest, CppUnit and Ruby.
;;
;; The back-ends probably need some more path options to work correctly.
;; Please let me know, as I'm not an expert on all of them.
;;
;; To install test-case-mode, add the following to your .emacs:
;; (add-to-list 'load-path "/path/to/test-case-mode")
;; (autoload 'test-case-mode "test-case-mode" nil t)
;; (autoload 'enable-test-case-mode-if-test "test-case-mode")
;; (autoload 'test-case-compilation-finish-run-all "test-case-mode")
;;
;; To enable it automatically when opening test files:
;; (add-hook 'find-file-hook 'enable-test-case-mode-if-test)
;;
;; If you want to run all visited tests after a compilation, add:
;; (add-hook 'compilation-finish-functions
;;           'test-case-compilation-finish-run-all)
;;
;; If failures have occurred, they are highlighted in the buffer and/or its
;; fringes (if fringe-helper.el is installed).
;;
;; fringe-helper is available at:
;; http://nschum.de/src/emacs/fringe-helper/
;;
;; Limitations:
;; C++ tests can be compiled in a multitude of ways.  test-case-mode currently
;; only supports running them if each test class comes in its own file.
;;
;;; Change Log:
;;
;;    Initial release.
;;
;;; Code:

(eval-when-compile (require 'cl))
(require 'compile)
(require 'fringe-helper nil t)

(dolist (err '("^test-case-mode not enabled$" "^Test not recognized$"
               "^Moved back before first failure$" "^Moved past last failure$"
               "^Test result buffer killed$"))
  (add-to-list 'debug-ignored-errors err))

(defgroup test-case nil
  "Unit test front-end"
  :group 'tools)

(defcustom test-case-backends
  '(test-case-junit-backend test-case-ruby-backend test-case-cxxtest-backend
    test-case-cppunit-backend)
  "*Test case backends.
Each function in this list is called with a command, which is one of these:

'supported: The function should return return non-nil, if the backend can
handle the current buffer.

'name: The function should return a string with the backend's name.

'command: The function should return the shell command to test the current
buffer.

'font-lock-keywords: The function should return font-lock keywords for the
current buffer.  They should be suitable for passing to
`font-lock-add-keywords'.

'failure-pattern: The function should return a list.  The first element
must be the regular expression that matches the failure description as
returned by the command.  The next elements should be the sub-expression
numbers that match file name, line, column, name plus line (a clickable link)
and error message. Each of these can be nil."
  :group 'test-case
  :type '(repeat function))

(defcustom test-case-ask-about-save t
  "*Non-nil means `test-case-mode' asks which buffers to save before running.
Otherwise, it saves all modified buffers without asking.  `test-case-mode'
will only offer to save buffers when the tests are run by interpreters.
Already compiled tests will be run without saving."
  :group 'test-case
  :type '(choice (const :tag "Save without asking" nil)
                 (const :tag "Ask before saving" t)))

(defcustom test-case-global-state-change-hook nil
  "*Hook run when the global test status changes.
Each function is called with two arguments, the old and the new value of
`test-case-global-state'."
  :group 'test-case
  :type 'hook)

(defcustom test-case-state-change-hook nil
  "*Hook run when the global test status changes.
Each function is called with two arguments, the old and the new value of
`test-case-state'."
  :group 'test-case
  :type 'hook)

(defcustom test-case-parallel-processes 1
  "*Number of tests to run concurrently."
  :group 'test-case
  :type '(choice (const :tag "Off" 1)
                 (integer)
                 (const :tag "Unlimited" t)))

(defcustom test-case-abort-on-first-failure nil
  "*Stop running test cases after the first failure occurs."
  :group 'test-case
  :type '(choice (const :tag "Keep running" nil)
                 (const :tag "Abort on first failure" t)))

(defcustom test-case-color-buffer-id t
  "*Color Buffer Identification?"
  :group 'test-case
  :type '(choice (const :tag "Off" nil)
                 (const :tag "On" t)))

(defcustom test-case-mode-line-info-position 1
  "*The position of the colored result dot in the mode-line."
  :group 'test-case
  :type '(choice (const :tag "Off" nil)
                 (integer :tag "Position")))

(defcustom test-case-result-context-lines nil
  "Display this many lines of leading context before the current message.
See `compilation-context-lines'."
  :group 'test-case
  :type '(choice integer (const :tag "No window scrolling" nil)))

;;; faces ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defface test-case-mode-line-success
  '((t (:inherit mode-line-buffer-id
        :background "dark olive green"
        :foreground "black")))
  "Face used for displaying a successful test result."
  :group 'test-case)

(defface test-case-mode-line-success-modified
  '((t (:inherit test-case-mode-line-success
        :foreground "orange")))
  "Face used for displaying a successful test result in a modified buffer."
  :group 'test-case)

(defface test-case-mode-line-failure
  '((t (:inherit mode-line-buffer-id
        :background "firebrick"
        :foreground "wheat")))
  "Face used for displaying a failed test result."
  :group 'test-case)

(defface test-case-mode-line-undetermined
  '((t (:inherit mode-line-buffer-id
        :background "orange"
        :foreground "black")))
  "Face used for displaying a unknown test result."
  :group 'test-case)

(defface test-case-failure
  '((t (:underline "firebrick1")))
  "Face used for displaying a failed test result."
  :group 'test-case)

(defface test-case-fringe
  '((t (:foreground "red")))
  "*Face used for bitmaps in the fringe."
  :group 'test-case)

(defface test-case-assertion
  '((t (:inherit font-lock-warning-face)))
  "*Face used for assertion commands."
  :group 'test-case)

(defface test-case-result-message
  '((((background dark)) (:foreground "#00bfff"))
    (((background light)) (:foreground "#006faa")))
  "*Face used for highlighting failure messages"
  :group 'test-case)

(defface test-case-result-file
  '((t :inherit font-lock-warning-face))
  "*Face used for highlighting file links"
  :group 'test-case)

(defface test-case-result-line
  '((t :inherit compilation-line-number))
  "*Face used for highlighting file link lines"
  :group 'test-case)

(defface test-case-result-column
  '((t :inherit compilation-column-number))
  "*Face used for highlighting file link columns"
  :group 'test-case)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar test-case-result-buffer-name "*Test Result*")

(defvar test-case-backend nil)
(make-variable-buffer-local 'test-case-backend)

(defun test-case-call-backend (command &optional buffer)
  (with-current-buffer (or buffer (current-buffer))
    (funcall test-case-backend command)))

(defsubst test-case-buffer-state (buffer)
  (buffer-local-value 'test-case-state buffer))

(defun test-case-buffer-list ()
  (let (buffers)
    (dolist (buffer (buffer-list))
      (and (buffer-local-value 'test-case-mode buffer)
           (push buffer buffers)))
    buffers))

(defun test-case-failed-buffer-list ()
  (let (buffers)
    (dolist (buffer (buffer-list))
      (and (buffer-local-value 'test-case-mode buffer)
           (eq (buffer-local-value 'test-case-state buffer) 'failure)
           (push buffer buffers)))
    buffers))

(defun test-case-process-list ()
  (let (processes)
    (dolist (proc (process-list))
      (when (process-get proc 'test-case-buffer)
        (push proc processes)))
    processes))

;;; buffer id ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar test-case-buffer-id-string nil)
(make-variable-buffer-local 'test-case-buffer-id-string)

(defun test-case-install-colored-buffer-id ()
  (when (stringp (car mode-line-buffer-identification))
    (setq test-case-buffer-id-string
          (copy-sequence (pop mode-line-buffer-identification)))
    (push test-case-buffer-id-string mode-line-buffer-identification)))

(defun test-case-remove-colored-buffer-id ()
  (kill-local-variable 'mode-line-buffer-identification))

(defun test-case-set-buffer-id-face (face)
  (when test-case-buffer-id-string
    (add-text-properties 0 (length test-case-buffer-id-string)
                         `(face ,face) test-case-buffer-id-string)))

;;; dot ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar test-case-dot-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] 'test-case-show-menu)
    map)
  "*Keymap used for test-case dot in mode-line.")

(defvar test-case-dot-tooltip
  "mouse-1: Display minor-mode-menu")

(defun test-case-make-dot (color &optional inner border)
  "Return an image representing a dot whose color is COLOR."
  (propertize " "
              'help-echo 'test-case-dot-tooltip
              'keymap test-case-dot-keymap
              'display
              `(image :type xpm
                      :data ,(format "/* XPM */
static char * data[] = {
\"18 13 4 1\",
\" 	c None\",
\".	c %s\",
\"x	c %s\",
\"+	c %s\",
\"                  \",
\"       +++++      \",
\"      +.....+     \",
\"     +.......+    \",
\"    +....x....+   \",
\"    +...xxx...+   \",
\"    +..xxxxx..+   \",
\"    +...xxx...+   \",
\"    +....x....+   \",
\"     +.......+    \",
\"      +.....+     \",
\"       +++++      \",
\"                  \"};"
                                     color (or inner color) (or border "black"))
                      :ascent center)))

(defvar test-case-dot-format (list (test-case-make-dot "gray10")))

(defun test-case-install-dot (&optional global)
  "Install the dot in the mode-line at `test-result-dot-position' or POSITION.
With argument GLOBAL install in mode-line's default value, without make sure
mode-line is local before installing."
  (test-case-remove-dot global)
  (when test-case-mode-line-info-position
    (let* ((mode-line (if global
                          (default-value 'mode-line-format)
                        (set (make-local-variable 'mode-line-format)
                             (copy-sequence mode-line-format))
                        mode-line-format))
           (pos (nthcdr test-case-mode-line-info-position mode-line)))
      (setcdr pos (cons test-case-dot-format (cdr pos))))))

(defun test-case-remove-dot (&optional globalp)
  "Remove the dot installed by `test-case-install-dot' from the mode-line."
  (if globalp
      (setq-default mode-line-format
                    (delq test-case-dot-format
                          (default-value 'mode-line-format)))
    (setq mode-line-format (delq test-case-dot-format mode-line-format))))

(defun test-case-update-dot (state)
  (setcar test-case-dot-format
          (case state
            (failure (test-case-make-dot "firebrick"))
            (running-failure (test-case-make-dot "firebrick" "orange"))
            (running (test-case-make-dot "orange"))
            (success (test-case-make-dot "dark olive green"))
            (success-modified (test-case-make-dot "dark olive green" "orange"))
            (otherwise (test-case-make-dot "gray10")))))

;;; states ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar test-case-state 'unknown
  "The state of the current buffer test.
This is either 'unknown, 'running, 'failure, 'success or 'success-modified")
(make-variable-buffer-local 'test-case-state)

(defvar test-case-global-state nil
  "The aggregated test states.
This is either 'unknown, 'running, 'running-failure, 'failure or 'success.")

(defun test-case-echo-state (state)
  (unless (eq state 'unknown)
    (message "Test %s" (case state
                         ('success "succeeded")
                         ('failure "failed")
                         ('running-failure "failed (continuing...)")
                         ('running "started")))))

(defun test-case-set-global-state (state)
  (unless (eq test-case-global-state state)
    (let ((old-state test-case-global-state))
      (setq test-case-global-state state)
      (test-case-update-dot state)
      (run-hook-with-args 'test-case-state-change-hook test-case-state state))))

(defun test-case-calculate-global-state (&optional buffers)
  "Calculate and the global state.
This assumes that no test is still running."
  (unless buffers (setq buffers (test-case-buffer-list)))
  (or (dolist (buffer buffers)
        (when (eq (buffer-local-value 'test-case-state buffer) 'failure)
          (return 'failure)))
      (dolist (buffer buffers)
        (unless (eq (buffer-local-value 'test-case-state buffer) 'success)
          (return 'unknown)))
      'success))

(defun test-case-buffer-changed (beg end)
  (when (eq test-case-state 'success)
    (test-case-set-buffer-state 'success-modified))
  (when (eq test-case-global-state 'success)
    (test-case-set-global-state 'success-modified))
  (remove-hook 'before-change-functions 'test-case-buffer-changed t))

(defun test-case-set-buffer-state (state &optional buffer)
  "Set BUFFER's `test-case-state' to STATE."
  (with-current-buffer (or buffer (current-buffer))
    (unless (eq state test-case-state)
      (let ((old-state test-case-state))

        (setq test-case-state state)

        (when test-case-color-buffer-id
          (test-case-set-buffer-id-face
           (case state
             ('success 'test-case-mode-line-success)
             ('success-modified 'test-case-mode-line-success-modified)
             ('running 'test-case-mode-line-undetermined)
             ('failure 'test-case-mode-line-failure)
             (otherwise 'mode-line-buffer-id))))

        (test-case-menu-update)

        (when (eq state 'success)
          (add-hook 'before-change-functions 'test-case-buffer-changed nil t))

        (run-hook-with-args 'test-case-state-change-hook old-state state)))))

;;; global mode ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar test-case-global-mode-map (make-sparse-keymap)
  "Keymap used by `test-case-global-mode'.")

(define-minor-mode test-case-global-mode
  "A minor mode keeping track of buffers in `test-case-mode'."
  nil nil test-case-global-mode-map :global t
  (if test-case-global-mode
      (progn
        (test-case-install-dot t)
        (test-case-set-global-state 'unknown))
    (test-case-set-global-state 'unknown)
    (test-case-remove-dot t)))

;;; mode ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar test-case-lighter " Test"
  "The mode-line string used by ``test-case-mode''.
It's value represents the test case type.")
(make-variable-buffer-local 'test-case-lighter)

(defvar test-case-mode-map (make-sparse-keymap)
  "Keymap used by `test-case-mode'.")

(defun test-case-detect-backend ()
  (when buffer-file-name
    (dolist (backend test-case-backends)
      (when (funcall backend 'supported)
        (setq test-case-backend backend
              test-case-lighter (concat " " (test-case-call-backend 'name)))
        (return t)))))

;;;###autoload
(define-minor-mode test-case-mode
  "A minor mode for test buffers.
Tests can be started with the commands `test-case-run' or
`test-case-run-all'.  If you want to run tests automatically after a
compilation, use `test-case-compilation-finish-run-all'.

When a run has finished, the results appear in a buffer named \"*Test
Result*\".  Clicking on the files will take you to the failure location,
as will `next-error' and `previous-error'.

The testing states are indicated visually.  The buffer name is colored
according to the result and a dot in the mode-line represents the global
state.  This behavior is customizable through `test-case-color-buffer-id'
and `test-case-mode-line-info-position'."
  nil test-case-lighter test-case-mode-map
  (if test-case-mode
      (condition-case err
          (if (not (test-case-detect-backend))
              (error "Test not recognized")
            (font-lock-add-keywords nil
                                    (test-case-call-backend 'font-lock-keywords)
                                    'prepend)
            (font-lock-fontify-buffer)
            (when test-case-color-buffer-id
              (test-case-install-colored-buffer-id))
            (test-case-global-mode 1)
            (add-hook 'kill-buffer-hook 'disable-test-case-mode nil t))
        (error (setq test-case-mode nil)))

    (font-lock-remove-keywords nil (test-case-call-backend 'font-lock-keywords))
    (test-case-remove-colored-buffer-id)
    (if (test-case-buffer-list)
        (test-case-set-global-state (test-case-calculate-global-state))
      (test-case-global-mode 0)))

  (test-case-menu-update))

(defun disable-test-case-mode ()
  (interactive)
  (test-case-mode 0))

;;;###autoload
(defun enable-test-case-mode-if-test ()
  "Turns on ``test-case-mode'' if this buffer is a recognized test."
  (ignore-errors (test-case-mode 1)))

;;;###autoload(add-hook 'find-file-hook 'enable-test-case-mode-if-test)

;;; menu ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar test-case-menu nil)
(defvar test-case-minor-mode-menu nil)

(defun tast-case-menu-format-buffer (buffer)
  (if (memq (test-case-buffer-state buffer) '(running failure))
      (format "%s (%s)" (buffer-name buffer)
              (if (eq (test-case-buffer-state buffer) 'running)
                  "running"
                "failed"))
    (buffer-name buffer)))

(defun test-case-menu-buffer-list (func list)
  "Build a menu with all test case buffers."
  (mapcar (lambda (buffer)
            (vector (tast-case-menu-format-buffer buffer)
                    `(lambda () (interactive)
                       (,func ,buffer))))
          (sort list (lambda (a b) (string< (buffer-name a) (buffer-name b))))))

(defun test-case-menu-build ()
  (let ((failed-tests (test-case-failed-buffer-list)))
    `("Tests"
      ["Run" test-case-run :visible test-case-mode]
      ["Run All" test-case-run-all]
      ("Run Buffer" . ,(test-case-menu-buffer-list
                        'test-case-run (test-case-buffer-list)))
      "-"
      ("Tests" . ,(test-case-menu-buffer-list
                   'switch-to-buffer (test-case-buffer-list)))
      ("Failures"
       :visible ,(if failed-tests t)
       ,@(test-case-menu-buffer-list 'switch-to-buffer failed-tests)))))

(defun test-case-menu-update ()
  (let ((menu (test-case-menu-build)))
    (easy-menu-define test-case-menu test-case-global-mode-map
      "Test case global menu"
      menu)
    (easy-menu-define test-case-minor-mode-menu nil
      "Test case minor mode menu"
      (append menu
              '("-"
                ["Turn Off minor mode" disable-test-case-mode]
                ["Help for minor mode"
                 (lambda () (interactive)
                   (describe-function 'test-case-mode))])))
    (define-key test-case-mode-map [(menu-bar) (x)] test-case-minor-mode-menu)))

(defun test-case-show-menu ()
  (interactive)
  (popup-menu test-case-menu))

;;; running ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar test-case-last-run nil)
(defvar test-case-current-run nil)
(defvar test-case-current-run-left nil)

(defun test-case-copy-result (from to)
  (with-current-buffer to
    (when (buffer-live-p to)
      (let ((inhibit-read-only t)
            (pos (point-max)))
        (goto-char pos)
        (insert-buffer-substring from nil nil)
        pos))))

(defun test-case-abort (&optional quiet)
  "Abort the currently running tests."
  (interactive)
  (dolist (buffer test-case-current-run-left)
    (when (buffer-live-p buffer)
      (test-case-set-buffer-state 'unknown buffer)))
  (setq test-case-current-run nil)
  (let ((processes (test-case-process-list))
        test-buffer)
    (when processes
      (dolist (process processes)
        (when (and (setq test-buffer (process-get process 'test-case-buffer))
                   (memq (process-status process) '(run stop))
                   ;; careful, kill-process mustn't set global state
                   (kill-process process))
          (when (buffer-live-p test-buffer)
            (test-case-set-buffer-state 'unknown test-buffer))))
      (test-case-set-global-state (test-case-calculate-global-state))
      (unless quiet
        (message "Test run aborted")))))

(defun test-case-process-sentinel (proc msg)
  (when (eq (process-status proc) 'exit)
    (let ((out-buffer (process-buffer proc))
          (test-buffer (process-get proc 'test-case-buffer))
          (result-buffer (process-get proc 'test-case-result-buffer))
          (keywords (process-get proc 'test-case-failure-pattern))
          (failure (/= 0 (process-exit-status proc)))
          (next (pop test-case-current-run-left))
          (more (test-case-process-list))
          (inhibit-read-only t))

      (delete-process proc)

      (unless (buffer-live-p out-buffer)
        (error "Test result buffer killed"))

      (with-current-buffer out-buffer
        (insert-char ?= fill-column)
        (newline))

      (when (buffer-live-p test-buffer)
        (test-case-set-buffer-state
         (if failure
             'failure
           (if (eq (process-get proc 'test-case-tick)
                   (buffer-modified-tick test-buffer))
               'success
           'success-modified))
         test-buffer))

      ;; Update the results.
      (when keywords
        (if (eq out-buffer result-buffer)
            (test-case-parse-result result-buffer keywords
                                    (process-get proc 'test-case-beg))
          (let ((beg (with-current-buffer result-buffer (point-max))))
            (test-case-copy-result out-buffer result-buffer)
            (test-case-parse-result result-buffer keywords beg)))

        (when (and failure test-case-abort-on-first-failure)
          (test-case-abort t)
          (setq more nil
                next nil)))

      (when failure
        (setq next-error-last-buffer result-buffer)
        (when (or next more)
          (unless (eq test-case-global-state 'running-failure)
            (test-case-set-global-state 'running-failure)
            (test-case-echo-state 'running-failure))))

      ;; Remove dead buffers
      (while (and next
                  (not (and (buffer-live-p next)
                            (buffer-local-value 'test-case-mode next))))
        (setq next (pop test-case-current-run-left)))

      (if next
          ;; continue
          (if (eq out-buffer result-buffer)
              ;; linear
              (test-case-run-internal next result-buffer out-buffer)
            ;; parallel, re-use out-buffer
            (with-current-buffer out-buffer
              (let ((inhibit-read-only t))
                (erase-buffer)
                (test-case-run-internal next result-buffer out-buffer))))
        ;; No more work to do.
        (unless (eq out-buffer result-buffer)
          (kill-buffer out-buffer))
        (unless more
          ;; all done
          (test-case-set-global-state (test-case-calculate-global-state))
          (test-case-echo-state
           (test-case-calculate-global-state test-case-current-run)))))))

(defun test-case-run-internal (test-buffer result-buffer &optional out-buffer)
  (let ((inhibit-read-only t)
        (default-directory (file-name-directory (buffer-file-name test-buffer)))
        command beg process)

    (unless out-buffer (setq out-buffer result-buffer))

    (with-current-buffer out-buffer
      (goto-char (setq beg (point-max)))
      (insert-char ?= fill-column)
      (newline)
      (condition-case err
          (insert (format "Test run: %s\n\n"
                          (setq command
                                (test-case-call-backend 'command test-buffer))))
      (error (insert (error-message-string err) "\n")
             (setq command "false"))))

    (setq process (start-process "test-case-process" out-buffer
                                 shell-file-name shell-command-switch command))
    (set-process-query-on-exit-flag process nil)
    (process-put process 'test-case-tick (buffer-modified-tick test-buffer))
    (process-put process 'test-case-buffer test-buffer)
    (process-put process 'test-case-result-buffer result-buffer)
    (process-put process 'test-case-failure-pattern
                 (test-case-call-backend 'failure-pattern test-buffer))
    (process-put process 'test-case-beg beg)

    (set-process-sentinel process 'test-case-process-sentinel)
    t))

(defun test-case-run-buffers (buffers)
  "Run the tests visited by BUFFERS.
Tests are run consecutively or concurrently according to
`test-case-parallel-processes'."
  (test-case-abort)

  (dolist (buffer buffers)
    (when (test-case-call-backend 'save buffer)
      (save-some-buffers (not test-case-ask-about-save))
      (return)))

  (dolist (buffer buffers)
    (test-case-remove-failure-overlays buffer)
    (test-case-set-buffer-state 'running buffer))

  (test-case-set-global-state 'running)
  (test-case-echo-state 'running)

  (setq test-case-current-run buffers
        test-case-current-run-left buffers)

  (let ((result-buffer (get-buffer-create test-case-result-buffer-name))
        (inhibit-read-only t)
        (processes (if (eq t test-case-parallel-processes)
                       (length test-case-current-run)
                     (max (or test-case-parallel-processes 1) 1))))

    (with-current-buffer result-buffer
      (erase-buffer)
      (setq buffer-read-only t)
      (buffer-disable-undo)
      (test-case-result-mode))

    (when test-case-current-run
      ;; start running
      (if (or (null (cdr test-case-current-run)) (= processes 1))
          (test-case-run-internal (pop test-case-current-run-left)
                                  result-buffer)
        ;; use temp buffers for output synchronisation
        (while (and test-case-current-run-left
                    (> processes 0))
          (test-case-run-internal (pop test-case-current-run-left)
                                  result-buffer
                                  (generate-new-buffer " *Test Run*"))
          (decf processes))))))

(defun test-case-run (&optional buffer)
  "Run the test in the current buffer.
Calling this aborts all running tests.  To run multiple tests use
`test-case-run-all' or `test-case-run-buffers'."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (unless test-case-mode
      (error "test-case-mode not enabled"))
    (test-case-run-buffers (setq test-case-last-run (list (current-buffer))))))

(defun test-case-run-again ()
  "Run the latest test again."
  (interactive)
  (test-case-run-buffers test-case-last-run))

(defun test-case-run-all ()
  "Run `test-case-run-buffers' on all tests currently visited by buffers."
  (interactive)
  (test-case-run-buffers (test-case-buffer-list)))

;;;###autoload
(defun test-case-compilation-finish-run-all (buffer result)
  "Post-compilation hook for running all tests after successful compilation.
Install this the following way:

\(add-hook 'compilation-finish-functions
          'test-case-compilation-finish-run-all\)"
  (and (string-match "*compilation.*" (buffer-name buffer)) ;; not for grep
       (equal result "finished\n")
       (test-case-run-all)))

;;; results ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar test-case-error-pos nil)
(make-variable-buffer-local 'test-case-error-pos)

(defvar test-case-error-overlays nil)
(make-variable-buffer-local 'test-case-error-overlays)

(defvar test-case-result-mode-map
  (let ((keymap (make-sparse-keymap)))
    (define-key keymap "q" 'bury-buffer)
    (define-key keymap [mouse-2] 'test-case-click)
    (define-key keymap [follow-link] 'mouse-face)
    (define-key keymap "\C-m" 'test-case-follow-link)
    keymap)
  "Keymap used for `test-case-result-mode'.")

(define-derived-mode test-case-result-mode fundamental-mode "Test result"
  "Major mode for test case results."
  (setq next-error-function 'test-case-next-error-function
        test-case-error-pos nil))

(defun test-case-switch-to-result-buffer ()
  "Switch to the result buffer of the last test run."
  (interactive)
  (let ((buffer (get-buffer test-case-result-buffer-name)))
    (if buffer
        (switch-to-buffer buffer)
      (message "No result buffer found"))))

(defun test-case-insert-failure-overlay (beg end buffer)
  "Insert an overlay marking a failure between BEG and END in BUFFER."
  (with-current-buffer buffer
    (and (fboundp 'fringe-helper-insert-region)
         (fboundp 'fringe-lib-load)
         (boundp 'fringe-lib-exclamation-mark)
         (push (fringe-helper-insert-region
                beg end
                (fringe-lib-load fringe-lib-exclamation-mark 'left-fringe)
                'left-fringe 'test-case-fringe)
               test-case-error-overlays))
    (push (make-overlay beg end) test-case-error-overlays)
    (overlay-put (car test-case-error-overlays) 'face 'test-case-failure)))

(defun test-case-remove-failure-overlays (buffer)
  "Remove all overlays added by `test-case-insert-failure-overlay' in BUFFER."
  (with-current-buffer buffer
    (mapc 'delete-overlay test-case-error-overlays)))

(defun test-case-result-add-markers (beg end find-file-p file line col)
  (let ((buffer (if find-file-p
                    (find-file-noselect file)
                  (find-buffer-visiting file)))
        (inhibit-read-only t)
        beg-marker end-marker)
    (when buffer
      (save-match-data
        (with-current-buffer buffer
          (save-excursion
            (goto-line line)
            (back-to-indentation)
            (setq beg-marker (copy-marker (point)))
            (end-of-line)
            (setq end-marker (copy-marker (point)))))
        (add-text-properties beg end
                             `(test-case-beg-marker ,beg-marker
                               test-case-end-marker ,end-marker))
        (test-case-insert-failure-overlay beg-marker end-marker buffer)))))

(defun test-case-result-supplement-markers (pos)
  (let* ((end (next-single-property-change pos 'test-case-failure))
         (beg (previous-single-property-change end 'test-case-failure)))
    (test-case-result-add-markers beg end t
                                  (get-text-property pos 'test-case-file)
                                  (get-text-property pos 'test-case-line)
                                  (get-text-property pos 'test-case-column))))

(defun test-case-propertize-message (file line col link msg)
  (and file
       (match-beginning file)
       (add-text-properties (match-beginning file) (match-end file)
                            '(face test-case-result-file)))
  (and line
       (match-beginning line)
       (add-text-properties (match-beginning line) (match-end line)
                            '(face test-case-result-line)))
  (and col
       (match-beginning col)
       (add-text-properties (match-beginning col) (match-end col)
                            '(face test-case-result-column)))
  (and link
       (match-beginning link)
       (add-text-properties (match-beginning link) (match-end link)
                            '(mouse-face highlight
                              follow-link t)))
  (and msg
       (match-beginning msg)
       (add-text-properties (match-beginning msg) (match-end msg)
                            '(face test-case-result-message
                                   mouse-face highlight
                                   follow-link t)))

  (let ((file (match-string-no-properties file))
        (line (string-to-number (match-string-no-properties line)))
        (col (when col (string-to-number (match-string-no-properties col)))))
    (add-text-properties (match-beginning 0) (match-end 0)
                         `(test-case-failure ,(current-time) ;; unique
                           test-case-file ,file
                           test-case-line ,line
                           test-case-column ,col))
    (test-case-result-add-markers (match-beginning 0) (match-end 0) nil
                                  file line col)))

(defun test-case-parse-result (result-buffer keywords &optional beg end)
  (with-current-buffer result-buffer
    (save-excursion
      (let ((inhibit-read-only t))
        (unless beg (setq beg (point-min)))
        (unless end (setq end (point-max)))
        (goto-char beg)
        (add-text-properties beg end 'test-case-file)
        (while (re-search-forward (car keywords) end t)
          (apply 'test-case-propertize-message (cdr keywords)))))))

(defun test-case-follow-link (pos)
  "Follow the link at POS in an error buffer."
  (interactive "d")
  (let ((marker (get-text-property pos 'test-case-beg-marker)))
    (unless (and marker (marker-buffer marker))
      (test-case-result-supplement-markers pos)))
  (let ((msg (copy-marker pos))
        (compilation-context-lines test-case-result-context-lines))
    (compilation-goto-locus msg (get-text-property pos 'test-case-beg-marker)
                            (get-text-property pos 'test-case-end-marker))
    (set-marker msg nil)))

(defun test-case-click (event)
  "Follow the link selected in an error buffer."
  (interactive "e")
  (with-current-buffer (window-buffer (posn-window (event-end event)))
    (test-case-follow-link (posn-point (event-end event)))))

;;; next-error ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun test-case-next-error (arg)
  (let ((pos test-case-error-pos))
    (setq arg (* 2 arg))
    (unless (get-text-property pos 'test-case-failure)
      (setq arg (1- arg)))
    (assert (> arg 0))
    (dotimes (i arg)
      (setq pos (next-single-property-change pos 'test-case-failure))
      (unless pos
        (error "Moved past last failure")))
    pos))

(defun test-case-previous-error (arg)
  (let ((pos test-case-error-pos))
    (assert (> arg 0))
    (dotimes (i (* 2 arg))
      (setq pos (previous-single-property-change pos 'test-case-failure))
      (unless pos
        (error "Moved back before first failure")))
    pos))

(defun test-case-next-error-function (arg reset)
  (when (or reset (null test-case-error-pos))
    (setq test-case-error-pos (point-min)))
  (setq test-case-error-pos
        (if (<= arg 0)
            (test-case-previous-error (- arg))
          (test-case-next-error arg)))
  (test-case-follow-link test-case-error-pos))

;;; follow-mode ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar test-case-result-follow-last-link nil)
(make-variable-buffer-local 'test-case-follow-last-link)

(define-minor-mode test-case-result-follow-mode
  "Minor mode for navigating test-case results.
When turned on, cursor motion in the result buffer causes automatic
display of the corresponding failure location.

Customize `next-error-highlight' to modify the highlighting."
  nil " Fol" nil
  :group 'test-case
  (if test-case-result-follow-mode
      (add-hook 'post-command-hook 'test-case-result-follow-hook nil t)
    (remove-hook 'post-command-hook 'test-case-result-follow-hook t)
    (kill-local-variable 'test-case-result-follow-last-link)))

(defun test-case-result-follow-hook ()
  (let ((beg (and (get-text-property (point) 'test-case-failure)
                  (get-text-property (point) 'follow-link)
                  (previous-single-property-change (point) 'follow-link))))
    (setq test-case-result-follow-last-link beg)
    (when beg
      (let ((next-error-highlight next-error-highlight-no-select)
            test-case-result-context-lines)
        (save-selected-window
          (save-excursion
            (test-case-follow-link beg)))))))

;;; back-end utils ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun test-case-grep (regexp)
  (save-restriction
    (widen)
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward regexp nil t)
        ;; Always return something, even if nothing was matched by the group.
        (or (match-string-no-properties 1) "")))))

(defun test-case-c++-inherits (class &optional namespace)
  "Test if a class in the current buffer inherits from CLASS in NAMESPACE.
CLASS and NAMESPACE need to be `regexp-quote'd."
  (if namespace
      (or (test-case-c++-inherits (concat namespace "::" class))
          (and (test-case-c++-inherits class)
               (or (test-case-grep (concat "using\s+" namespace "\s+"
                                           class ";"))
                   (test-case-grep (concat "using\s+" namespace "\\."
                                           class ";")))))
    (test-case-grep (concat ":\s*"
                            (eval-when-compile
                              (regexp-opt '("public" "private" "protected")))
                            "\s+" class))))

;;; junit ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defcustom test-case-junit-java-executable (executable-find "java")
  "The Java executable used to run JUnit tests."
  :group 'test-case
  :type 'file)

(defcustom test-case-junit-java-arguments "-ea"
  "The command line arguments used to run JUnit tests."
  :group 'test-case
  :type 'string)

(defcustom test-case-junit-classpath
  '(test-case-junit-guess-root
    test-case-junit-jde-classpath
    test-case-junit-classpath-from-env)
  "*Directories that make up the CLASSPATH for JUnit tests.
Instead of directories, each element can also be a function returning a
CLASSPATH for the current buffer."
  :group 'test-case
  :type '(repeat (choice (function :tag "Function")
                         (directory :tag "Directory"))))

(defun test-case-junit-build-classpath ()
  (mapconcat (lambda (entry) (or (if (stringp entry) entry (funcall entry)) ""))
             test-case-junit-classpath
             ":"))

(defun test-case-junit-classpath-from-env ()
  "Return the value of the CLASSPATH environment variable."
  (getenv "CLASSPATH"))

(defun test-case-junit-grep-package ()
  (test-case-grep "package\\s +\\([[:alnum:].]+\\)\\s *;"))

(defun test-case-junit-guess-root ()
  "Guess the classpath for a JUnit test by looking at the package.
If the classpath ends in \"src/\", the same path is added again using \"bin/\".
Additionally the CLASSPATH environment variable is used."
  (let ((package (test-case-junit-grep-package))
        (path (nreverse (cons "" (split-string buffer-file-name "/" t))))
        root)
    (when package
      (setq path (nthcdr (1+ (length (split-string package "\\." t))) path))
      (or (and (equal (car path) "src")
               (setq root (mapconcat 'identity
                                     (reverse (cons "bin" (cdr path))) "/"))
               (file-exists-p root)
               root)
          (mapconcat 'identity (nreverse path) "/")))))

(defun test-case-junit-jde-classpath ()
  (when (derived-mode-p 'jde-mode)
    (with-no-warnings
      (let ((classpath (if jde-compile-option-classpath
                           jde-compile-option-classpath
                         (jde-get-global-classpath)))
            (symbol (if 'jde-compile-option-classpath
                        'jde-compile-option-classpath
                      'jde-global-classpath)))
        (when classpath
          (jde-build-classpath classpath symbol))))))

(defun test-case-junit-class ()
  (let ((package (test-case-junit-grep-package))
        (class (file-name-sans-extension
                (file-name-nondirectory buffer-file-name))))
    (if package
        (concat package "." class)
      class)))

(defun test-case-junit-command ()
  (format "%s %s -classpath %s org.junit.runner.JUnitCore %s"
          test-case-junit-java-executable test-case-junit-java-arguments
          (test-case-junit-build-classpath) (test-case-junit-class)))

(defvar test-case-junit-font-lock-keywords
  (eval-when-compile
    `((,(concat "\\_<assert"
                (regexp-opt '("True" "False" "Equals" "NotNull" "Null" "Same"
                              "NotSame"))
                "\\_>")
       (0 'test-case-assertion prepend)))))

(defconst test-case-junit-assertion-re
  "junit\\.framework\\.AssertionFailedError: \\(.*\\)
\\(^[ \t]+at .*
\\)*?")

(defconst test-case-junit-backtrace-re-1
  "[ \t]+at [^ \t\n]+(\\(\\(")

(defconst test-case-junit-backtrace-re-2
  "\\):\\([[:digit:]]+\\)\\)")

(defun test-case-junit-failure-pattern ()
  (let ((file (regexp-quote (file-name-nondirectory buffer-file-name))))
    (list (concat "\\(" test-case-junit-assertion-re "\\)?"
                  test-case-junit-backtrace-re-1 file
                  test-case-junit-backtrace-re-2)
      5 6 nil 4 2)))

(defvar test-case-junit-import-regexp
  "import\\s +junit\\.framework\\.\\(TestCase\\|\\*\\)")

(defvar test-case-junit-extends-regexp
  "extends\\s +TestCase")

(defun test-case-junit-backend (command)
  "JUnit back-end for `test-case-mode'.
When using the JUnit backend, you'll need to make sure the classpath is
configured correctly.  The classpath is determined by
`test-case-junit-classpath-func' and guessed by default."
  (case command
    ('name "JUnit")
    ('supported (and (derived-mode-p 'java-mode)
                     (test-case-grep test-case-junit-import-regexp)
                     (test-case-grep test-case-junit-extends-regexp)))
    ('command (test-case-junit-command))
    ('failure-pattern (test-case-junit-failure-pattern))
    ('font-lock-keywords test-case-junit-font-lock-keywords)))

;; ruby ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defcustom test-case-ruby-executable (executable-find "ruby")
  "The Ruby executable used to run Ruby tests."
  :group 'test-case
  :type 'file)

(defcustom test-case-ruby-arguments ""
  "The command line arguments used to run Ruby tests."
  :group 'test-case
  :type 'string)

(defvar test-case-ruby-font-lock-keywords
  (eval-when-compile
    `((,(concat
         "\\_<assert"
         (regexp-opt '("" "_equal" "_not_equal" "_match" "_no_match" "_nil"
                       "_not_nil" "_in_delta" "_instance_of" "_kind_of" "_same"
                       "_not_same" "_raise" "_nothing_raised" "_throws"
                       "_nothing_thrown" "_respond_to" "_send" "_operator"))
         "\\_>")
       (0 'test-case-assertion prepend)))))

(defvar test-case-ruby-failure-pattern
  (eval-when-compile
    `(,(concat "^[^ \t]+([^ \t]+) "
               "\\[\\(\\([^:]+\\):\\([[:digit:]]+\\)\\)\\]:\n"
               "\\(\\(.+\n\\)*\\)\n")
      2 3 nil 1 4)))

(defun test-case-ruby-backend (command)
  "Ruby Test::Unit back-end for `test-case-mode'."
  (case command
    ('name "Test::Unit")
    ('supported (and (derived-mode-p 'ruby-mode)
                     (test-case-grep "require\s+['\"]test/unit['\"]")))
    ('command (concat test-case-ruby-executable " "
                      test-case-ruby-arguments " " buffer-file-name))
    ('save t)
    ('failure-pattern test-case-ruby-failure-pattern)
    ('font-lock-keywords test-case-ruby-font-lock-keywords)))

;; cxxtest ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defcustom test-case-cxxtest-executable-name-func 'file-name-sans-extension
  "A function that returns the executable name for a cxxtest test."
  :group 'test-case
  :type 'function)

(defun test-case-cxxtest-p ()
  "Test if the current buffer is a cxxtest."
  (and (derived-mode-p 'c++-mode)
       ;; header included
       (test-case-grep "#include\s+\\([<\"]\\)cxxtest[/\\]TestSuite.h[>\"]")
       ;; class inherited (depending on used namespace)
       (or (test-case-c++-inherits "CxxTest::TestSuite")
           (and (test-case-c++-inherits "TestSuite")
                (or (test-case-grep (concat "using\s+namespace\s+CxxTest;"))
                    (test-case-grep (concat "using\s+CxxTest.TestSuite;")))))))


(defun test-case-cxxtest-command ()
  (let ((executable (funcall test-case-cxxtest-executable-name-func
                             buffer-file-name)))
    (unless (file-exists-p executable)
      (error "Executable %s not found" executable))
    (when (file-newer-than-file-p buffer-file-name executable)
      (error "Test case executable %s out of date" executable))
    executable))

(defvar test-case-cxxtest-font-lock-keywords
  (eval-when-compile
    `((,(concat
         "\\_<TS_"
         (regexp-opt '("FAIL" "ASSERT" "ASSERT_EQUALS" "ASSERT_SAME_DATA"
                       "ASSERT_DELTA" "ASSERT_DIFFERS" "ASSERT_LESS_THAN"
                       "ASSERT_LESS_THAN_EQUALS" "ASSERT_PREDICATE"
                       "ASSERT_RELATION" "ASSERT_THROWS" "ASSERT_THROWS_EQUALS"
                       "ASSERT_THROWS_ASSERT" "ASSERT_THROWS_ANYTHING"
                       "ASSERT_THROWS_NOTHING" "WARN" "TRACE"))
         "\\_>")
       (0 'test-case-assertion prepend)))))

(defun test-case-cxxtest-failure-pattern ()
  (let ((file (regexp-quote (file-name-nondirectory (buffer-file-name)))))
    (list (concat "^\\(\\(" file "\\):\\([[:digit:]]+\\)\\): \\(.*\\)$")
          2 3 nil 1 4)))

(defun test-case-cxxtest-backend (command)
  "CxxTest back-end for `test-case-mode'
Since these tests can't be dynamically loaded by the runner, each test has
to be compiled into its own executable.  The executable should have the
same name as the test, but without the extension.  If it doesn't,
customize `test-case-cxxtest-executable-name-func'"
  (case command
    ('name "CxxTest")
    ('supported (test-case-cxxtest-p))
    ('command (test-case-cxxtest-command))
    ('failure-pattern (test-case-cxxtest-failure-pattern))
    ('font-lock-keywords test-case-cxxtest-font-lock-keywords)))

;; cppunit ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defcustom test-case-cppunit-executable-name-func 'file-name-sans-extension
  "A function that returns the executable name for a CppUnit test."
  :group 'test-case
  :type 'function)

(defun test-case-cppunit-p ()
  "Test if the current buffer is a CppUnit test."
  (and (derived-mode-p 'c++-mode)
       ;; header included
       (test-case-grep "#include\s+\\([<\"]\\)cppunit[/\\]TestCase.h[>\"]")
       ;; class inherited (depending on used namespace)
       (or (test-case-c++-inherits "CppUnit::TestCase")
           (and (test-case-c++-inherits "TestCase")
                (or (test-case-grep (concat "using\s+namespace\s+CppUnit;"))
                    (test-case-grep (concat "using\s+CppUnit.TestCase;")))))))

(defun test-case-cppunit-command ()
  (let ((executable (funcall test-case-cppunit-executable-name-func
                             buffer-file-name)))
    (unless (file-exists-p executable)
      (error "Executable %s not found" executable))
    (when (file-newer-than-file-p buffer-file-name executable)
      (error "Test case executable %s out of date" executable))
    executable))

(defvar test-case-cppunit-font-lock-keywords
  (eval-when-compile
    `((,(concat
         "\\_<CPPUNIT_"
         (regexp-opt '("ASSERT" "ASSERT_MESSAGE" "FAIL" "ASSERT_EQUAL"
                       "ASSERT_EQUAL_MESSAGE" "ASSERT_DOUBLES_EQUAL"
                       "ASSERT_THROW" "ASSERT_NO_THROW" "ASSERT_ASSERTION_FAIL"
                       "ASSERT_ASSERTION_PASS"))
         "\\_>")
       (0 'test-case-assertion prepend)))))

(defun test-case-cppunit-failure-pattern ()
  (let ((file (regexp-quote (file-name-nondirectory (buffer-file-name)))))
    (list (concat "^[0-9]+) test:.*\\(line: \\([0-9]+\\) \\(.+\\)\\)\n"
                  "\\(\\(.+\n\\)+\\)\n\n")
          2 3 nil 1 4)))

(defun test-case-cppunit-backend (command)
  "CxxTest back-end for `test-case-mode'
Since these tests can't be dynamically loaded by the runner, each test has
to be compiled into its own executable.  The executable should have the
same name as the test, but without the extension.  If it doesn't,
customize `test-case-cppunit-executable-name-func'"
  (case command
    ('name "CppUnit")
    ('supported (test-case-cppunit-p))
    ('command (test-case-cppunit-command))
    ('failure-pattern (test-case-cppunit-failure-pattern))
    ('font-lock-keywords test-case-cppunit-font-lock-keywords)))

(provide 'test-case-mode)
;;; test-case-mode.el ends here
