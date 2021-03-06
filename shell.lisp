;;
;; shell.lisp - The shell object and it's options.
;;

(in-package :lish)

(declaim (optimize (speed 0) (safety 3) (debug 3) (space 0) (compilation-speed 0)))
;(declaim (optimize (speed 3) (safety 3) (debug 3) (space 0) (compilation-speed 0)))

;; (defkeymap *default-lish-esc-keymap*
;;   "Keymap for Lish."
;;   `((#\o		. shell-expand-line)))

;; (defkeymap *lish-esc-keymap* nil)

(defkeymap *lish-default-keymap*
  "Keymap for Lish."
  `((,(ctrl #\v)	. shell-expand-line)))

;; @@@ I want to change all the lish-* accessors to shell-*
(defclass shell ()
  ((exit-flag
    :initarg :exit-flag
    :accessor lish-exit-flag
    :documentation "Set to true to exit the shell.")
   (exit-values
    :initarg :exit-values
    :accessor lish-exit-values
    :documentation "List of values to return to the caller.")
   (aliases
    :accessor lish-aliases
    :documentation "Hash table of aliases.")
   (global-aliases
    :accessor lish-global-aliases
    :documentation "Hash table of global aliases.")
   (editor
    :accessor lish-editor
    :documentation "Line editor instance.")
   (keymap
    :accessor lish-keymap
    :documentation "Keymap for the line editor.")
   (old-pwd
    :accessor lish-old-pwd
    :initform nil
    :documentation "The last working directory.")
   (dir-list
    :accessor lish-dir-list
    :initform nil
    :documentation "Directory list for pushd and popd.")
   (jobs
    :accessor lish-jobs :initarg :jobs :initform nil
    :documentation "List of jobs.")
   (start-time
    :initarg :start-time :accessor lish-start-time :type integer
    :documentation
    "Seconds elapsed since some time. Defaults to since shell was started.")
   (options
    :initarg :options :accessor lish-options :initform nil
    :documentation "Operator configurable options."))
  (:default-initargs
   :exit-flag nil
   :exit-values '()
   :start-time (get-universal-time)
   :keymap (copy-keymap *lish-default-keymap*))
  (:documentation "A lispy system command shell."))

(defmethod initialize-instance :after
    ((sh shell) &rest initargs &key &allow-other-keys)
  (declare (ignore initargs))
;  (setf (slot-value sh 'commands) (make-hash-table :test #'equal))
  (setf (slot-value sh 'aliases) (make-hash-table :test #'equal))
  (setf (slot-value sh 'global-aliases) (make-hash-table :test #'equal))
  ;; Set default keymap
  (when (or (not (slot-boundp sh 'keymap)) (not (slot-value sh 'keymap)))
    (setf (slot-value sh 'keymap)
	  (copy-keymap *lish-default-keymap*)))
  ;; Copy the objecs from the defined option list, and set the default values.
  (loop :with o :for opt :in *options* :do
     (setf o (shallow-copy-object opt)
	   (arg-value o) (arg-default o))
     (push o (lish-options sh)))
  (init-commands))

;; Most things that are designed to be settable by the user should likely
;; be made into an option. Options defined by DEFOPTION are accessible like a
;; typical class slot acessor method on the shell object, as well as being an
;; easily accesible using the 'opt' command.
;;
;; We think of options like they are arguments for the shell, and use
;; the argument class to store them. That way we can use the same completion
;; and conversion.

(defun find-option (sh name)
  "Find the option of the shell SH, named NAME. Error if there is none."
  (or (find (string name) (lish-options sh) :key #'arg-name :test #'equalp)
      (error 'shell-error :format "No such option ~w"
	     :arguments (list name))))

(defun set-option (sh name value)
  "Set the option named NAME, for shell SH, to VALUE."
  (setf (arg-value (find-option sh name)) value))

(defun get-option (sh name)
  "Get the option named NAME, for shell SH."
  (arg-value (find-option sh name)))

(defmacro defoption (name &rest arg)
  "Define a shell option named NAME, with the properties in arg. The syntax
is like Lish arguments, e.g.:
  (defoption \"foo\" type :help \"Make sure to foo.\" :short-arg #\\f)"
  (let ((sym (symbolify (s+ "LISH-" name)))
	(name-string (string-downcase name)))
    `(progn
       ;; Access options as if they were in the shell object.
       (defgeneric ,sym (shell)
	 (:documentation ,(s+ "Return the value of " name-string ".")))
       (defmethod ,sym ((sh shell)) (get-option sh ,name-string))
       (defgeneric (setf ,sym) (value shell)
	 (:documentation ,(s+ "Set the value of " name-string ".")))
       (defmethod (setf ,sym) (value (sh shell))
	 (set-option sh ,name-string value))
       (push (make-argument ',(cons name-string arg))
	     *options*))))

(setf *options* nil)

(defoption prompt object
  :help "Normal prompt. Output if there is no prompt function. Output
with SYMBOLIC-PROMPT-TO-STRING and FORMAT-PROMPT. See the documentation for
those functions for more detail about prompt formatting."
;;  :default nil
  :default
  ((:green "%u") "@" (:cyan "%h") " " (:white "%w") (:red ">") " ")
 )

(defoption prompt-function function
  :help "Function which takes a SHELL and returns a string to output as the
prompt."
;;  :default make-prompt	       ; N.B.: #'make-prompt doesn't work here
  )

(defoption sub-prompt string
  :help "String to print when prompting for more input."
  :default "- ")	; @@@ maybe we need sub-prompt-char & sub-prompt-func?

(defoption ignore-eof integer
  :help "If true, prevent the EOF (^D) character from exiting the shell. If a 
number ignore it that many times before exiting."
  :default nil)

(defoption debug boolean
  :help "True to enter the debugger when there is an error."
  :default nil)

(defoption collect-stats boolean
  :help "True to collect statistics on commands."
  :default nil)

(defoption autoload-from-asdf boolean
  :help
  "True to try to load unknown commands from an ASDF system of the same name."
  :default t)

(defoption history-expansion boolean
  :help "True if !<integer> should expand to a history item."
  :default nil)

(defoption expand-braces boolean
  :help "True to expand braces in shell commands."
  :default t)

(defoption colorize boolean
  :help "True to colorize the command line."
  :default t)

(defoption auto-cd boolean
  :help "True to treat a directroy as a command to change to that directory."
  :default t)

;;; @@@ Shouldn't this be in the shell object?
;;; @@@ But it doesn't do anything right now anyway.
(defvar *shell-path* '()
  "List of directories to autoload commands from.")

;; EOF
