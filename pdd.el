;;; pdd.el --- HTTP library & Async Toolkit -*- lexical-binding: t -*-

;; Copyright (C) 2025 lorniu <lorniu@gmail.com>

;; Author: lorniu <lorniu@gmail.com>
;; URL: https://github.com/lorniu/pdd.el
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))
;; Version: 0.1

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; This package provides a robust and elegant library for HTTP requests and
;; asynchronous operations in Emacs. It featuring a single, consistent API that
;; works identically across different backends, maximizing code portability and
;; simplifying development.
;;
;;  - Unified Backend:
;;
;;    Seamlessly utilize either the high-performance `curl' backend or the
;;    built-in `url.el'. It significantly enhances `url.el', adding essential
;;    features like cookie-jar support, streaming support, multipart uploads,
;;    comprehensive proxy support (HTTP/SOCKS with auth-source integration),
;;    smart request/response data conversion and automatic retries.
;;
;;  - Developer Friendly:
;;
;;    Offers a minimalist yet flexible API that is backend-agnostic, intuitive
;;    and easy to use. Features like variadic callbacks and header abbreviations
;;    can help you achieve more with less code.
;;
;;  - Powerful Async Foundation:
;;
;;    Features a native, cancellable `Promise/A+' implementation and intuitive
;;    `async/await' syntax for clean, readable concurrent code. Includes
;;    integrated async helpers for timers and external processes. Also includes
;;    a queue mechanism for fine-grained concurrency control when making multiple
;;    asynchronous requests.
;;
;;  - Highly Extensible:
;;
;;    Easily customize request/response flows using a clean transformer pipeline
;;    and object-oriented (EIEIO) backend design. This makes it easy to add new
;;    features or event entirely new backends.
;;
;; Usage:
;;
;;    (pdd "https://httpbin.org/uuid" #'print)
;;
;;    (pdd "https://httpbin.org/post"
;;      :headers '((bear "hello world"))
;;      :params '((name . "jerry") (age . 9))
;;      :data '((key . "value") (file1 "~/aaa.jpg"))
;;      :done (lambda (json) (alist-get 'file json))
;;      :proxy "socks5://localhost:1085"
;;      :cookie-jar (pdd-cookie-jar "~/xxx.mycookie"))
;;
;;    (pdd-async
;;      (let* ((r1 (await (pdd "https://httpbin.org/ip")
;;                        (pdd "https://httpbin.org/uuid")))
;;             (r2 (await (pdd "https://httpbin.org/anything"
;;                          :data `((ip . ,(alist-get 'origin (car r1)))
;;                                  (id . ,(alist-get 'uuid (cadr r1))))))))
;;        (message "> Got: %s" (alist-get 'form r2))))
;;
;; See README.md of https://github.com/lorniu/pdd.el for more

;;; Code:

(require 'cl-lib)
(require 'eieio)
(require 'help)
(require 'url-http)
(require 'ansi-color)

(defgroup pdd nil
  "HTTP Library Adapter."
  :group 'network
  :prefix 'pdd-)

(defcustom pdd-debug nil
  "Debug flag."
  :type '(choice boolean symbol))

(defvar pdd-debug-buffer nil
  "Where to show the log message.")

(defun pdd-log (tag &rest args)
  "Output log to *Messages* buffer using syntax of `message'.
TAG usually is the name of current http backend.  ARGS should be fmt and
rest arguments."
  (declare (indent 1))
  (when (and pdd-debug
             (or (eq tag pdd-debug)
                 (and (eq pdd-debug t) (not (eq tag 'task)))))
    (cl-loop with sub = nil
             with fmt = (format "[%s] " (or tag "pdd"))
             with display = (lambda (args)
                              (setq args (nreverse args)
                                    args (cons (concat fmt (car args)) (cdr args)))
                              (if pdd-debug-buffer
                                  (with-current-buffer (get-buffer-create pdd-debug-buffer)
                                    (goto-char (point-max))
                                    (princ (apply #'format args) (current-buffer))
                                    (princ "\n" (current-buffer)))
                                (apply #'message args)))
             for el in args
             if (and (stringp el) (string-match-p "%[sSdx]" el))
             do (progn (if sub (funcall display sub)) (setq sub (list el)))
             else do (push el sub)
             finally (funcall display sub))))

(defconst pdd-common-cache (make-hash-table :test 'equal))

(defmacro pdd-with-common-cache (key &rest body)
  "Execute BODY and cache its result under KEY."
  (declare (indent 1))
  (let ((keysmb (gensym)) (valsmb (gensym)) (cache (gensym)))
    `(let* ((,keysmb ,key)
            (,cache (gethash ,keysmb pdd-common-cache 'no-x-cache)))
       (if (not (eq ,cache 'no-x-cache))
           ,cache
         (let ((,valsmb (progn ,@body)))
           (puthash ,keysmb ,valsmb pdd-common-cache)
           ,valsmb)))))

(defun pdd-detect-charset (content-type)
  "Detect charset from CONTENT-TYPE header."
  (when content-type
    (pdd-with-common-cache (cons 'charset content-type)
      (setq content-type (downcase (format "%s" content-type)))
      (if (string-match "charset=\\s-*\\([^; \t\n\r]+\\)" content-type)
          (intern (match-string 1 content-type))
        'utf-8))))

(defun pdd-binary-type-p (content-type)
  "Check if current CONTENT-TYPE represents binary data."
  (when content-type
    (pdd-with-common-cache (cons 'binaryp content-type)
      (cl-destructuring-bind (mime sub)
          (split-string content-type "/" nil "[ \n\r\t]")
        (not (or (equal mime "text")
                 (and (equal mime "application")
                      (string-match-p
                       (concat "json\\|xml\\|yaml\\|font"
                               "\\|javascript\\|php\\|form-urlencoded")
                       sub))))))))

(defun pdd-gen-url-with-params (url params)
  "Generate a URL by appending PARAMS to URL with proper query string syntax."
  (if-let* ((ps (if (consp params) (pdd-object-to-string 'query params) params)))
      (concat url (unless (string-match-p "[?&]$" url) (if (string-match-p "\\?" url) "&" "?")) ps)
    url))

(defconst pdd-multipart-boundary
  (format "pdd-boundary-%x%x=" (random) (random))
  "A string used as multipart boundary.")

(defun pdd-format-formdata (alist)
  "Generate multipart/form-data payload from ALIST.

Handles both regular fields and file uploads with proper boundary formatting.

ALIST format:
  Regular field: (KEY . VALUE)
  File upload: (KEY FILENAME [CONTENT-TYPE])

Returns the multipart data as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (when alist
      (insert "--" pdd-multipart-boundary "\r\n")
      (cl-loop for (key . value) in alist
               for i from 1
               for is-last = (= i (length alist))
               for key-str = (format "%s" key)
               if (consp value) ; File: (FILENAME [MIME-TYPE])
               do (let* ((filename (expand-file-name (car value)))
                         (mime-type (or (cadr value) "application/octet-stream"))
                         (encoded-filename (url-encode-url (file-name-nondirectory filename))))
                    (insert (format "Content-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\n"
                                    key-str encoded-filename))
                    (insert (format "Content-Type: %s\r\n\r\n" mime-type))
                    (insert-file-contents-literally filename)
                    (goto-char (point-max)))
               else ; Regular field
               do (insert (format "Content-Disposition: form-data; name=\"%s\"\r\n\r\n%s"
                                  key-str (or value "")))
               do (insert "\r\n--" pdd-multipart-boundary)
               do (unless is-last (insert "\r\n")))
      (insert "--"))
    (buffer-string)))

(defun pdd-extract-http-headers ()
  "Extract http headers from the current response buffer."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (forward-line 1)
      (cl-loop for el in (mail-header-extract)
               collect (cons (car el) (string-trim (cdr el)))))))

(defun pdd-encode-time-string (date-string)
  "Parse HTTP DATE-STRING into Emacs internal time format."
  (let* ((date-time (parse-time-string date-string)))
    (unless (car date-time)
      (setq date-time (append '(0 0 0) (nthcdr 3 date-time))))
    (apply #'encode-time date-time)))

(defun pdd-split-string-from-= (string &optional url-decode)
  "Split STRING at the first = into two parts.
Try to unhex the second part when URL-DECODE is not nil."
  (let* ((p (cl-position ?= string))
         (k (if p (substring string 0 p) string))
         (v (if p (substring string (1+ p)))))
    (cons k (when (and v (not (string-empty-p v)))
              (funcall (if url-decode #'url-unhex-string #'identity)
                       (string-trim v))))))

(defun pdd-generic-parse-url (url)
  "Return an URL-struct of the parts of URL with cache support."
  (pdd-with-common-cache (list 'url-obj url)
    (when (> (hash-table-count pdd-common-cache) 234)
      (clrhash pdd-common-cache))
    (url-generic-parse-url url)))

(defun pdd-parse-proxy-url (proxy-url)
  "Parse PROXY-URL into a plist with :type, :host, :port, :user, :pass.

Supports formats like:
  http://localhost
  https://example.com:8080
  socks5://user:pass@127.0.0.1:1080"
  (cl-assert (stringp proxy-url))
  (pdd-with-common-cache (cons 'parse-proxy-url proxy-url)
    (let* ((url (url-generic-parse-url proxy-url))
           (type (intern (url-type url)))
           (host (url-host url))
           (port (or (url-port url)
                     (pcase type
                       ('http 80)
                       ('https 443)
                       ('socks5 1080)
                       (_ 8080))))
           (user (url-user url))
           (pass (url-password url)))
      `( :type ,type :host ,host :port ,port
         ,@(when user `(:user ,user))
         ,@(when pass `(:pass ,pass))))))

(defun pdd-parse-set-cookie (cookie-string &optional url-decode)
  "Parse HTTP Set-Cookie COOKIE-STRING with optional URL-DECODE.

Link:
  https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Set-Cookie
  https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis-11

Return a plist containing all cookie attributes."
  (when (and (stringp cookie-string) (not (string-empty-p cookie-string)))
    (when-let* ((pairs (split-string (string-trim cookie-string) ";\\s *" t))
                (names (pdd-split-string-from-= (car pairs) url-decode))
                (cookie (list :name (car names) :value (cdr names))))
      (cl-loop for pair in (cdr pairs)
               for (k . v) = (pdd-split-string-from-= pair url-decode)
               do (pcase (setq k (intern (concat ":" (downcase k))))
                    (:domain
                     (when v (plist-put cookie k v)))
                    (:path
                     (when v (plist-put cookie k (downcase v))))
                    (:expires
                     (when-let* ((date (ignore-errors (pdd-encode-time-string v))))
                       (plist-put cookie k date)))
                    (:max-age
                     (when (and v (string-match-p "^-?[0-9]+$" v))
                       (plist-put cookie k (string-to-number v))))
                    (:samesite
                     (when (and v (member (downcase v) '("strict" "lax" "none")))
                       (plist-put cookie k (downcase v))))
                    (:priority
                     (when (and v (member (downcase v) '("low" "medium" "high")))
                       (plist-put cookie k (downcase v))))
                    ((or :secure :httponly :partitioned)
                     (plist-put cookie k t))
                    (_ nil))
               finally return (if (plist-get cookie :domain) cookie
                                (plist-put cookie :host-only t))))))

(defun pdd-parse-request-cookies (cookies-string)
  "Parse an HTTP request COOKIES-STRING to list contains every cookie as a plist."
  (unless (or (null cookies-string) (string-empty-p cookies-string))
    (let ((pairs (split-string cookies-string "; ?" t)))
      (mapcar (lambda (pair)
                (let ((key-value (split-string pair "=" t)))
                  (when (= (length key-value) 2)
                    (list :name (string-trim (car key-value))
                          :value (string-trim (cadr key-value))))))
              pairs))))

(defvar url-http-codes)

(defun pdd-http-code-text (http-status-code)
  "Return text description of the HTTP-STATUS-CODE."
  (caddr (assoc http-status-code url-http-codes)))

(cl-defmacro pdd-with-record ((&rest vars) record &rest body)
  "Destructuring bind VARS for RECORD using by BODY."
  (declare (indent 2) (debug ((&rest symbolp) form body)))
  (let ((var (gensym)))
    `(let ((,var ,record))
       (cl-symbol-macrolet
           ,(cl-loop for i in vars for n from 1
                     unless (eq i '_)
                     collect (list i `(aref ,var ,n)))
         ,@body))))

(defun pdd-string-iequal (string1 string2)
  "Compare STRING1 and STRING2 case-insensitively."
  (eq t (compare-strings string1 0 nil string2 0 nil t)))

(defun pdd-function-arglist (function)
  "Return the required argument list of FUNCTION to build decorate function."
  (cl-loop for arg in
           (if (or (null function) (equal (func-arity function) '(0 . many)))
               '(a1)
             (help-function-arglist function))
           until (memq arg '(&rest &optional &key))
           collect arg))

(defun pdd-funcall (fn args)
  "Call function FN with the first N arguments from ARGS, where N is FN's arity."
  (declare (indent 1))
  (let ((n (car (func-arity fn))))
    (apply fn (cl-loop for i from 1 to n for x in args collect x))))

(cl-defgeneric pdd-string-to-object (_type string)
  "Convert STRING to an Elisp object based on the specified content TYPE."
  (:method ((_ (eql 'json)) string)
           (json-parse-string string :object-type 'alist))
  string)

(cl-defgeneric pdd-object-to-string (type _object)
  "Convert Elisp OBJECT to string based on the specified content TYPE."
  (:method ((_ (eql 'json)) object)
           ;; pity, json-serialize may fail in some cases
           (require 'json)
           (json-encode object))
  (:method ((_ (eql 'query)) object)
           (url-build-query-string
            (cl-loop for item in object
                     when (consp item)
                     collect (if (car-safe (cdr item)) item
                               (list (car item) (cdr item))))))
  (user-error "No support for type %s" type))


;;; Core

(defcustom pdd-base-url nil
  "Concat with url when the url is not started with http.
Use as dynamical binding usually."
  :type '(choice (const nil) string))

(defcustom pdd-default-sync 'unset
  "The sync style when no :sync specified explicitly for function `pdd'.
It's value should be t or nil.  Default unset means not specified."
  :type '(choice (const :tag "Unspecified" unset)
                 (const :tag "Synchronous" t)
                 (const :tag "Asynchronous" nil)))

(defcustom pdd-user-agent
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.75 Safari/537.36"
  "Default user agent used by request."
  :type 'string)

(defcustom pdd-default-proxy nil
  "Default proxy used by the http request.

This should be a url string in format proto://[user:pass@]host:port or a
function return such a url string proxy."
  :type '(choice (choice (const nil) string) string function))

(defcustom pdd-default-timeout 30
  "Default timetout seconds for the request."
  :type 'natnum)

(defcustom pdd-default-retry 1
  "Default retry times when request timeout."
  :type 'natnum)

(defvar pdd-retry-condition
  (lambda (err) (string-match-p "timeout\\|408" (format "%s" err)))
  "Function determine whether should retry the request.")

(defvar pdd-header-rewrite-rules
  '((ct          . ("Content-Type"  . "%s"))
    (ct-bin      . ("Content-Type"  . "application/octet-stream"))
    (json        . ("Content-Type"  . "application/json"))
    (json-u8     . ("Content-Type"  . "application/json; charset=utf-8"))
    (www-url     . ("Content-Type"  . "application/x-www-form-urlencoded"))
    (www-url-u8  . ("Content-Type"  . "application/x-www-form-urlencoded; charset=utf-8"))
    (acc-github  . ("Accept"        . "application/vnd.github+json"))
    (basic       . ("Authorization" . "Basic %s"))
    (bear        . ("Authorization" . "Bearer %s"))
    (auth        . ("Authorization" . "%s %s"))
    (keep-alive  . ("Connection"    . "Keep-Alive"))
    (ua-emacs    . ("User-Agent"    . "Emacs Agent")))
  "Header abbreviation system for simpfying request definitions.

Template Placeholders:
  %s - Replaced with provided arguments

Usage Examples:
  json → (\"Content-Type\" . \"application/json\")
  (bear \"token\") → (\"Authorization\" . \"Bearer token\")
  (auth \"Basic\" \"creds\") → (\"Authorization\" . \"Basic creds\")

They are be replaced when transforming request.")

(defvar pdd-default-cookie-jar nil
  "Default cookie jar used when not specified in requests.

The value can be either:
- A cookie-jar instance, or
- A function that returns a cookie-jar, signature (&optional requests)

This variable is used as a fallback when no cookie jar is explicitly
provided in individual requests.")

(defvar pdd-default-queue nil
  "Default request queue used by asynchronous `pdd' calls.

The value can be either:
- A queue instance, or
- A function that returns a queue instance, signature (&optional request)

This variable is used as a fallback when no queue is explicitly provided
in individual requests.")

(defvar pdd-default-error-handler #'pdd--default-error-handler
  "The default error handler that display errors when they are not handled by user.

The signature of the handler is (error &optional request).

When error occurrs and no :fail specified, this will perform as the handler.
Besides globally set, it also can be dynamically binding in let.")

(defun pdd--default-error-handler (err &optional req)
  "Default value for `pdd-default-error-handler' to deal with ERR for REQ."
  (pdd-log 'fail "display error with default-error-handler")
  (if (atom err) ; maybe a string
      (setq err `(user-error ,err))
    (when (eq (car err) 'error) ; avoid 'peculiar error'
      (setf (car err) 'user-error)))
  (let ((abort-flag (and req (with-no-warnings (oref req abort-flag)))))
    (message
     "[%s] %s"
     (if abort-flag abort-flag "unhandled error")
     (string-trim
      (if (get (car err) 'error-conditions)
          (error-message-string err)
        (mapconcat (lambda (e) (format "%s" e)) err ", "))))))

(defconst pdd-default-request-transformers
  '(pdd-transform-req-done
    pdd-transform-req-filter
    pdd-transform-req-fail
    pdd-transform-req-headers
    pdd-transform-req-cookies
    pdd-transform-req-data
    pdd-transform-req-proxy
    pdd-transform-req-finally)
  "List of functions that transform the request object in sequence.

Each transformer is a function that takes the current request object as its
single argument.  Transformers are applied in the order they appear in this
list, with each transformer able to modify the request object before passing
it to the next.

This list contains built-in transformers that provide essential functionality.
While you may change them by override `pdd-request-transformers' to add
additional transformers to customize behavior, you should not remove or reorder
the built-in transformers unless you fully understand the consequences.")

(defconst pdd-default-response-transformers
  '(pdd-transform-resp-init
    pdd-transform-resp-headers
    pdd-transform-resp-cookies
    pdd-transform-resp-decode
    pdd-transform-resp-body)
  "List of functions that process and transform the response buffer sequentially.

Each transformer is a function that operates on the current response buffer.
Transformers are applied in the order they appear in this list, with each
transformer able to modify the buffer state before passing it to the next.

This list contains core transformers that handle essential response processing
stages.  While you may change them by override `pdd-response-transformers' to
add additional transformers to extend functionality, you should not remove or
reorder the built-in transformers unless you fully understand the consequences.")

(defvar pdd-default-headers nil)
(defvar pdd-default-data nil)
(defvar pdd-default-done nil)
(defvar pdd-default-filter nil)

(eval-when-compile
  (defvar pdd--dynamic-context-vars
    '(default-directory
      pdd-base-url
      pdd-default-sync
      pdd-user-agent
      pdd-default-proxy
      pdd-default-timeout
      pdd-default-retry
      pdd-default-cookie-jar
      pdd-default-error-handler
      pdd-default-headers
      pdd-default-data
      pdd-default-done
      pdd-default-filter)
    "List of dynamic variables whose bindings should penetrate async callbacks."))

(defun pdd--capture-dynamic-context ()
  "Capture the current values of variables in `pdd--dynamic-context-vars'."
  (cl-loop for var in pdd--dynamic-context-vars
           if (boundp var) collect (cons var (symbol-value var))))

(defmacro pdd--with-restored-dynamic-context (context &rest body)
  "Execute BODY with dynamic variables restored from CONTEXT (an alist)."
  (declare (indent 1) (debug t))
  (let ((ctx-sym (gensym "context-")))
    `(let* ((,ctx-sym ,context)
            ,@(mapcar (lambda (var-val)
                        `(,(car var-val) (cdr (assoc ',(car var-val) ,ctx-sym))))
                      (mapcar #'list pdd--dynamic-context-vars)))
       ,@body)))

;; Backend

(defclass pdd-backend ()
  ((insts :allocation :class :initform nil))
  "Backend class."
  :abstract t)

(cl-defmethod make-instance ((class (subclass pdd-backend)) &rest slots)
  "Ensure CLASS with same SLOTS only has one instance."
  (if-let* ((key (sha1 (format "%s" slots)))
            (insts (oref-default class insts))
            (old (cdr-safe (assoc key insts))))
      old
    (let ((inst (cl-call-next-method)))
      (prog1 inst (oset-default class insts `((,key . ,inst) ,@insts))))))

(defclass pdd-http-backend (pdd-backend)
  ((user-agent :initarg :user-agent
               :initform nil
               :type (or string null))
   (proxy :initarg :proxy
          :type (or string function null)
          :initform nil))
  "Used to send http request."
  :abstract t)

;; Task (Promise/A+)

(defun pdd-task ()
  "An object represents Promise/A+ compliant promise with signal support.

Slots of task:
    status/1, values/2, reason/3, callbacks/4,
    signal-function/5,
    reject-handled-p/6, inhibit-default-rejection-p/7.

VALUE of status:
    pending, fulfilled and rejected, default nil if not SUPPLIED.

Each callback with function signature:
    (on-fulfilled on-rejected child-task captured-context)."
  ;;              0        1   2   3   4   5   6   7
  (record 'pdd-task 'pending nil nil '() nil nil nil))

(defun pdd-task-p (obj)
  "Judge if OBJ is a `pdd-task'."
  (eq (type-of obj) 'pdd-task))

(defun pdd-task-ensure (value)
  "Ensure VALUE is a task instance."
  (if (pdd-task-p value) value (pdd-resolve value)))

(defmacro pdd-with-new-task (&rest body)
  "Help macro, execute BODY with a new task bound to `it', returning the task.
Provide a `:signal function' anywhere in BODY to set signal function for task."
  (declare (debug t))
  (cl-labels ((repl-signal (form)
                (cond ((atom form) form)
                      ((cl-find :signal form)
                       (let* ((pos (cl-position :signal form))
                              (tail (nthcdr pos form)))
                         (append (cl-subseq form 0 pos)
                                 (cons `(aset it 5 ,(cadr tail)) (cddr tail)))))
                      (t (cons (repl-signal (car form))
                               (repl-signal (cdr form)))))))
    `(let ((it (pdd-task))) ,@(repl-signal body) it)))

(defun pdd-then (task &optional on-fulfilled on-rejected)
  "Register callbacks to be called when the TASK is resolved or rejected.
ON-FULFILLED ON-REJECTED are the callbacks for success and fail."
  (declare (indent 1))
  (unless (pdd-task-p task)
    (user-error "Task must be a `pdd-task' instance"))
  (pdd-with-new-task
   (let ((context (pdd--capture-dynamic-context)))
     (pdd-log 'task "    then | %s" (aref task 3))
     (when (and on-rejected (functionp on-rejected))
       (aset task 6 t)) ; mark as handled by downstream
     (pcase (aref task 1)
       ('pending (push (list on-fulfilled on-rejected it context) (aref task 4)))
       (_ (pdd-task--execute task (list on-fulfilled on-rejected it context))))
     (pdd-log 'task "        -> %s" (aref task 3) "        -> %s" it))))

(defun pdd-resolve (&rest args)
  "Resolve an existed task or create a new resolved task.

If (car ARGS) is `pdd-task' then resolve it with values is (cdr args).

Otherwise, create a new `pdd-task' which is rejected because of (car args)."
  (declare (indent 1))
  (if (or (not (car args)) (not (pdd-task-p (car args))))
      (pdd-with-new-task
       (aset it 1 'fulfilled)
       (aset it 2 args))
    (let* ((task (car args)) (values (cdr args)) (obj (car values)))
      (pdd-log 'task " resolve | %s, value: %s" task values)
      (cond ((not (eq (aref task 1) 'pending)) nil)
            ((eq task obj)
             (pdd-reject task (list 'type-error "Cannot resolve task with itself")))
            ((pdd-task-p obj)
             (pcase (aref obj 1)
               ('pending
                (pdd-then obj
                  (lambda (v) (pdd-resolve task v))
                  (lambda (r) (pdd-reject task r))))
               ('fulfilled
                (pdd-resolve task (aref obj 2)))
               ('rejected
                (pdd-reject task (aref obj 3)))))
            ((or (cl-typep obj 'eieio-object) (functionp obj))
             (condition-case err1
                 (let ((called nil)
                       (then (ignore-errors (with-no-warnings (eieio-oref obj 'then)))))
                   (if (functionp then)
                       (funcall then obj
                                (lambda (r)
                                  (unless called
                                    (setq called t)
                                    (pdd-resolve task r)))
                                (lambda (r)
                                  (unless called
                                    (setq called t)
                                    (pdd-reject task r))))
                     (pdd-resolve task obj)))
               (error (pdd-reject task err1))))
            (t (pdd-task--settle task 'fulfilled values))))))

(defun pdd-reject (&rest args)
  "Reject an existed task or create a new rejected task.

If (car ARGS) is `pdd-task' then reject it with reason (cadr args) and maybe
with more metadata in (cddr args), such as execution context.

Otherwise, create a new `pdd-task' which is rejected because of (car args)."
  (declare (indent 1))
  (if (or (not (car args)) (not (pdd-task-p (car args))))
      (pdd-with-new-task
       (aset it 1 'rejected)
       (aset it 3 (car args)))
    (let ((task (car args)) (reason (cdr args)))
      (pdd-log 'task "  reject | %s, reason: %s" task reason)
      (pdd-task--settle task 'rejected reason))))

(defun pdd-signal (task &optional signal)
  "Send a SIGNAL to the pending TASK to run the signal function if exists."
  (pdd-with-record (status _ _ callbacks signal-fn) task
    (when (eq status 'pending)
      (pdd-log 'task "  signal | %s, signal: %s" task signal)
      (if (functionp signal)
          (funcall signal)
        (when (functionp signal-fn)
          (pdd-funcall signal-fn (list signal)))))))

(defun pdd-task--settle (task status v)
  "Settle TASK to STATUS with V is value or reason."
  (pdd-with-record (s values reason callbacks _ reject-handled-p inhibit-default-rejection-p) task
    (unless (eq s 'pending)
      (user-error "Cannot settle non-pending task"))
    (unless (memq status '(fulfilled rejected))
      (user-error "Pending task only can be changed to fulfilled or rejected"))
    (pcase (setf s status)
      ('fulfilled
       (setf values v))
      ('rejected
       (setf reason v)
       ;; used to catch the final unhandled rejection, the way like javascript
       (when (and (null callbacks)
                  (not reject-handled-p)
                  (not inhibit-default-rejection-p))
         (run-with-idle-timer 0.1 nil #'pdd-task--reject-unhandled task v)))
      (_ (user-error "Wrong status settled")))
    (when callbacks ; propagate the flag to child task
      (let ((child-task (nth 2 (car callbacks))))
        (aset child-task 7 inhibit-default-rejection-p)))
    (while callbacks
      (let ((cb (pop callbacks)))
        ;; This should be executed as a micro-task-queue
        (run-at-time 0 nil (lambda () (pdd-task--execute task cb)))))))

(defun pdd-task--execute (task callback)
  "Execute a single CALLBACK for the TASK."
  (pdd-log 'task "        -> %s" callback)
  (when callback
    (cl-destructuring-bind (on-fulfilled on-rejected child-task context) callback
      (condition-case err1
          (pdd-with-record (status values reason) task
            (pcase status
              ('fulfilled
               (if (functionp on-fulfilled)
                   (let ((result (pdd--with-restored-dynamic-context context
                                   (pdd-funcall on-fulfilled values))))
                     (if (pdd-task-p result)
                         (pdd-then result
                           (lambda (v) (pdd-resolve child-task v))
                           (lambda (r) (pdd-reject child-task r)))
                       (pdd-resolve child-task result)))
                 (apply #'pdd-resolve child-task values)))
              ('rejected
               (if (functionp on-rejected)
                   (let ((result (pdd--with-restored-dynamic-context context
                                   (pdd-funcall on-rejected reason))))
                     (if (pdd-task-p result)
                         (pdd-then result
                           (lambda (v) (pdd-resolve child-task v))
                           (lambda (r) (pdd-reject child-task r)))
                       (pdd-resolve child-task result)))
                 (apply #'pdd-reject child-task reason))))
            (pdd-log 'task "        -> %s" task))
        (error (pdd-reject child-task err1))))))

(defun pdd-task--reject-unhandled (task error)
  "Default TASK rejection function when ERROR unhandled at last."
  (cl-macrolet
      ((deal-error-with-default-error-handler ()
         `(when pdd-default-error-handler
            (when (and (eq (aref task 1) 'rejected) ; still rejected
                       (not (aref task 6)) ; still not handled
                       (not (aref task 7))) ; and default not inhibited
              (condition-case err
                  (funcall pdd-default-error-handler (car error))
                (error (message "Error executing default rejection handler: %s" err)))))))
    (if-let* ((context (cadr error)))
        (pdd--with-restored-dynamic-context context
          (deal-error-with-default-error-handler))
      (deal-error-with-default-error-handler))))

(defun pdd-chain (task &rest callbacks)
  "Chain multiple CALLBACKS to execute sequentially on the result of TASK.

Creates a task chain where each callback in CALLBACKS is executed in order,
with each receiving the result of the previous operation.

Supports error handling via the :fail keyword, if present, it must be followed
by a function that will catch the final task.

NOTICE: variable `pdd-default-sync' always be nil in the inner context."
  (declare (indent 1))
  (let* ((pdd-default-sync nil)
         (pos (cl-position :fail callbacks))
         (reject (when pos
                   (if (functionp (ignore-errors (nth (1+ pos) callbacks)))
                       (progn (pop (nthcdr pos callbacks))
                              (pop (nthcdr pos callbacks)))
                     (user-error "Key :fail should be a funtion"))))
         (task (if (cl-every #'functionp callbacks)
                   (cl-reduce (lambda (acc fn) (pdd-then acc fn))
                              callbacks :initial-value (pdd-task-ensure task))
                 (user-error "Every callback should be a function"))))
    (if reject (pdd-then task #'identity reject) task)))

(defun pdd-all (&rest tasks)
  "Wait for all TASKS to complete and return a new task.

NOTICE: variable `pdd-default-sync' always be nil in the inner context."
  (pdd-with-new-task
   (if (null tasks)
       (pdd-resolve it nil)
     (let* ((pdd-default-sync nil)
            (tasks (mapcar #'pdd-task-ensure tasks))
            (results (make-vector (length tasks) nil))
            (remaining (length tasks))
            (has-settled nil))
       (cl-loop for task in tasks
                for i from 0
                do (let ((index i))
                     (pdd-then task
                       (lambda (value)
                         (unless has-settled
                           (aset results index value)
                           (cl-decf remaining)
                           (when (zerop remaining)
                             (setq has-settled t)
                             (pdd-resolve it (cl-coerce results 'list)))))
                       (lambda (reason)
                         (unless has-settled
                           (setq has-settled t)
                           (pdd-reject it reason)
                           (pdd-task--signal-cancel tasks))))))))))

(defun pdd-any (&rest tasks)
  "Wait for any of TASKS to succeed and return a new task.

NOTICE: variable `pdd-default-sync' always be nil in the inner context."
  (pdd-with-new-task
   (if (null tasks)
       (pdd-reject it "No tasks provided")
     (let* ((pdd-default-sync nil)
            (tasks (mapcar #'pdd-task-ensure tasks))
            (errors (make-vector (length tasks) nil))
            (remaining (length tasks))
            (has-fulfilled nil))
       (cl-loop for task in tasks
                for i from 0
                do (let ((index i))
                     (pdd-then task
                       (lambda (value)
                         (unless has-fulfilled
                           (setq has-fulfilled t)
                           (pdd-resolve it value)
                           (pdd-task--signal-cancel tasks)))
                       (lambda (reason)
                         (unless has-fulfilled
                           (setf (nth index errors) reason)
                           (cl-decf remaining)
                           (when (zerop remaining)
                             (pdd-reject it (cl-coerce errors 'list))))))))))))

(defun pdd-race (&rest tasks)
  "Wait for first settled of the TASKS, return a new task.

NOTICE: variable `pdd-default-sync' always be nil in the inner context."
  (pdd-with-new-task
   (if (null tasks)
       (pdd-reject it "No tasks provided")
     (let* ((pdd-default-sync nil)
            (tasks (mapcar #'pdd-task-ensure tasks))
            (has-settled nil))
       (cl-loop for task in tasks
                do (pdd-then task
                     (lambda (value)
                       (unless has-settled
                         (setq has-settled t)
                         (pdd-resolve it value)
                         (pdd-task--signal-cancel tasks)))
                     (lambda (reason)
                       (unless has-settled
                         (setq has-settled t)
                         (pdd-reject it reason)
                         (pdd-task--signal-cancel tasks)))))))))

(defun pdd-task--signal-cancel (tasks)
  "Send cancel signals to all TASKS."
  (dolist (task tasks)
    (when (eq (aref task 1) 'pending)
      (pdd-signal task 'cancel))))

(defconst pdd-task--timer-pool (make-hash-table :weakness 'key))

(defun pdd-clear-timer-tool ()
  "Clear `pdd-task--timer-pool'."
  (maphash (lambda (k _) (cancel-timer k)) pdd-task--timer-pool)
  (clrhash pdd-task--timer-pool))

(defun pdd--wrap-task-handlers (task done fail fine &rest fine-args)
  "Wrap TASK with DONE/FAIL handlers and with FINE and FINE-ARGS for cleanup."
  (pdd-then task
    (if (and done (not (functionp done)))
        (lambda () (unwind-protect done
                     (ignore-errors (pdd-funcall fine fine-args))))
      (let ((args (pdd-function-arglist (or done #'identity))))
        `(lambda (,@args)
           (unwind-protect
               (,(or done #'identity) ,@args)
             (ignore-errors (pdd-funcall ,fine ,fine-args))))))
    (lambda (reason &optional context)
      (unwind-protect
          (if fail
              (funcall fail reason context)
            (if (consp reason)
                (signal (car reason) (cdr reason))
              (user-error "%s" reason)))
        (ignore-errors (pdd-funcall fine fine-args))))))

(defun pdd-delay-task (time &optional value)
  "Create a promise that resolve VALUE after a specified TIME delay.

Arguments:
  TIME:  Same as the first argument of `run-at-time'
  VALUE: Optional value to resolve with (can be a function)

Returns:
  A promise object that will resolve after the specified delay.

Examples:
  (setq t1 (pdd-delay-task 5 \"hello\"))
  (pdd-then t1 (lambda (r) (message r)))
  (pdd-signal t1 \\='abort) ; the task can be cancelled by signal"
  (declare (indent 1))
  (pdd-with-new-task
   (let* ((context (pdd--capture-dynamic-context))
          (timer (run-at-time
                  time nil (lambda ()
                             (pdd--with-restored-dynamic-context context
                               (condition-case err
                                   (progn
                                     (when (functionp value)
                                       (setq value (funcall value)))
                                     (pdd-resolve it value))
                                 (error (pdd-reject it err))))))))
     :signal (lambda ()
               (if timer (cancel-timer timer))
               (pdd-reject it 'abort))
     (puthash timer it pdd-task--timer-pool))))

(defun pdd-timeout-task (time)
  "Create a new task that reject with timeout at time TIME.
TIME is same as the argument of `run-at-time'."
  (pdd-with-new-task
   (let ((timer (run-at-time time nil (lambda () (pdd-reject it 'timeout)))))
     :signal (lambda ()
               (if timer (cancel-timer timer))
               (pdd-reject it 'abort))
     (puthash timer it pdd-task--timer-pool))))

(cl-defun pdd-interval-task (secs count func &key init done fail fine)
  "Create a new task that executes FUNC for COUNT times at every SECS.

Use the return function of FUNC to explicitly give a resolve value to task and
then exit it, otherwise the internal will finished with null value resolved.

Also, the task can be cancelled by signal.

Arguments:

  SECS:  Seconds, a natnum number
  COUNT: Number of times to execute FUNC. Can be:
         * A number (execute N times)
         * t (execute indefinitely), nil (only one time)
         * A function with signature (&optional index) to check dynamically
  FUNC:  Function to execute, with signature (&optional index return-fn timer):
         * index: Current execution count (1-based)
         * return-function: Function to call to stop future executions
         * the timer itself
  INIT:  Optional function to execute after timer is created (&optional timer)
  DONE:  Optional function as resolved-fn when interval finished
  FAIL:  Optional function as rejected-fn when interval failed
  FINE:  Optional function always execute either success or fail

Return a `pdd-task' object representing the scheduled task which has two values
to be resolves: (index-of-interval-task-when-quit, return-value).

Example:

    (pdd-interval-task 1 5
      (lambda (i)
        (message \"Seq #%d\" i)))

    (pdd-interval-task 1 t
      (lambda (i ret)
        (if (> (random 10) 5)
            (funcall ret 777777))
          (message \"Seq #%d\" i)))

    ;; Task chain
    (pdd-then
        (pdd-interval-task 1 3
          (lambda (i return)
            (if (> (random 10) 6)
                (funcall return 666)
              (message \"Seq #%d\" i))))
      (lambda (v i) (message \"round %s, return: %s\" i v))
      (lambda (err) (message \"failed with error: %s\" err)))

    ;; Same as above
    (pdd-interval-task 1 3
      (lambda (i return)
        (if (> (random 10) 6)
            (funcall return 666)
          (message \"Seq #%d\" i)))
      :done (lambda (v i) (message \"round %s, return: %s\" i v))
      :fail (lambda (err) (message \"failed with error: %s\" err)))

    ;; Cancel the task
    (setq task1 (pdd-interval-task ...))
    (pdd-signal task1 \\='abort)"
  (declare (indent 2))
  (pdd-with-new-task
   (let* ((n 0)
          (task it)
          (timer nil)
          (context (pdd--capture-dynamic-context))
          (return-fn (lambda (&optional v rejected-p)
                       (if (timerp timer)
                           (cancel-timer timer))
                       (if rejected-p
                           (pdd-reject task v context)
                         (pdd-resolve task v n)))))
     (unless count (setq count 1))
     :signal (lambda () (funcall return-fn 'abort t))
     (when init
       (run-at-time 0 nil (lambda () (pdd-funcall init (list timer)))))
     (setq timer
           (run-at-time
            0 secs (lambda ()
                     (condition-case err
                         (pdd--with-restored-dynamic-context context
                           (if (or (and (numberp count)
                                        (>= n count))
                                   (and (functionp count)
                                        (not (pdd-funcall count (list (1+ n))))))
                               (funcall return-fn)
                             (cl-incf n)
                             (when (functionp func)
                               (pdd-funcall func (list n return-fn timer)))))
                       (error (funcall return-fn err t))))))
     (setq it (pdd--wrap-task-handlers it done fail fine timer))
     (puthash timer it pdd-task--timer-pool))))

(defvar pdd--proc-send-need-newline '("tee" "echo"))

(cl-defun pdd-process-task (cmd &rest args &key env as filter init done fail fine &allow-other-keys)
  "Create a promise-based task for managing external processes.

Arguments:

  CMD:     Executable name (string)
           * if this is t, ARGS will be wrapped to shell command
  ARGS:    List of command arguments
           * Element can be string, symbol or list
           * They will be auto flatten and stringify, so write any way you want
  ENV:     Extra process environment settings, string or list
  AS:      Transform process output specify type, function or abbrev symbol
           * If this is symbol line, split result to lines list
           * If this is a function, use its return value as result
           * Otherwise, just return the process output literally
  FILTER:  Process filter function (lambda (process string))
  INIT:    Post-creation callback (lambda (process))
           * If TYPE is pipe, and this is a string, then send it to proc pipe
           * If this is a function, just do something to proc manually with it
  DONE:    Success callback (lambda (output exit-status))
  FAIL:    Error handler (lambda (error-message))
  FINE:    Finalizer (lambda (process))

Smart cmd and args syntax:

  (pdd-process-task \"ls\" :done #\\='print)
  (pdd-process-task \"ls\" \"-a\" \"-l\" :done #\\='print)
  (pdd-process-task \"ls\" \"-a -l\" :done #\\='print)
  (pdd-process-task \"ls\" \\='(\"-a -l\")) ; those in list will not be splitted
  (pdd-process-task \\='ls \\='(-a -r) \\='-l :done #\\='print) ; auto stringify
  (pdd-process-task \"ls -a -r\" :done #\\='print) ; shell command format string
  (pdd-process-task t \\='(tee \"~/aaa.txt\") :init \"pipe this to tee to save\")

Bind extra proc environments:

  (pdd-process-task \\='ls :env \"X=11\") ; a string for only one
  (pdd-process-task \\='ls :env \\='(\"X=11\" \"Y=22\")) ; a list for multiple
  (pdd-process-task \\='ls :env \\='((x . 11) (y . 22))) ; alist is recommended
  (pdd-process-task \\='ls :env \\='((xpath f1 f2) (x . 33))) ; paths auto join

Callbacks for convenience:

  (pdd-process-task \\='(ls -l) :as \\='line :done \\='print)
  (pdd-process-task \\='(ls -l) :as \\='my-parse-fn :done \\='my-done-fn)

  (pdd-process-task \\='ls
    :init (lambda (proc) (extra-init-job proc))
    :done (lambda (res)  (message \"%s\" res))
    :fail (lambda (err)  (message \"EEE: %s\" err))
    :fine (lambda (proc) (extra-clean-up proc)))

Play with task chain:

  (pdd-chain (pdd-process-task \\='ip \"addr\")
    (lambda (r) (split-string r \"\\n\"))
    (lambda (r) (cl-remove-if-not (lambda (e) (string-match-p \"^[0-9]\" e)) r))
    (lambda (r) (mapcar (lambda (e) (cadr (split-string e \":\"))) r))
    (lambda (r) (pdd-interval-task 1 5 (lambda (i) (message \"%s\" i)) :done r))
    (lambda (r) (message \"> %s\" (nth (random (length r)) r))))

Returns a `pdd-task' object that can be canceled using `pdd-signal'"
  (declare (indent defun))
  (ignore env as filter init done fail fine) ; parse from args later, add this to silence linter
  (let (cmd-args keywords program)
    ;; parse arguments, cl-defun is different from common lisp defun
    (cl-loop for arg in (cons cmd args) for i from -1
             until (keywordp arg)
             append (if (consp arg)
                        (mapcar (lambda (s)
                                  (if (or (stringp s) (memq s '(nil t))) s
                                    (format "%s" s)))
                                arg)
                      (if (memq arg '(nil t)) (list arg)
                        (split-string-shell-command (format "%s" arg))))
             into lst finally
             (setq cmd-args lst keywords (cl-subseq args i)))
    (if (eq (car cmd-args) t) ; shell-command
        (setq program (cadr cmd-args)
              cmd-args (list shell-file-name shell-command-switch
                             (mapconcat #'identity (cdr cmd-args) " ")))
      (setq program (car cmd-args)))
    (cl-destructuring-bind (&key env as filter init done fail fine &allow-other-keys) keywords
      (pdd-with-new-task
       (let* ((task it)
              (proc nil)
              (proc-name (format "pdd-proc-%s-%s" program (+ 10000 (random 10000))))
              (proc-buffer (generate-new-buffer (format " *%s*" proc-name)))
              (proc-envs (cl-loop for item in (ensure-list env)
                                  if (consp item)
                                  collect (format "%s=%s"
                                                  (upcase (format "%s" (car item)))
                                                  (string-join (ensure-list (cdr item)) path-separator))
                                  if (stringp item) collect item))
              (process-environment (append proc-envs process-environment))
              (exit-status nil)
              (killed-by-user nil)
              (context (pdd--capture-dynamic-context))
              (signal-fn (lambda (sig)
                           (when (eq sig 'cancel)
                             (setq killed-by-user t)
                             (when (process-live-p proc)
                               (delete-process proc)))))
              (filter-fn (lambda (p string)
                           (with-current-buffer (process-buffer p)
                             (insert (ansi-color-apply string))
                             (when filter
                               (pdd-funcall filter (list string p))))))
              (as-line-fn (lambda ()
                            (let (lines)
                              (save-excursion
                                (goto-char (point-min))
	                            (while (not (eobp))
	                              (setq lines (cons (buffer-substring-no-properties (line-beginning-position) (line-end-position)) lines))
	                              (forward-line 1))
	                            (nreverse lines)))))
              (sentinel-fn (lambda (p event)
                             (with-current-buffer (process-buffer p)
                               (pdd-log 'cmd "event: %s" event)
                               (unwind-protect
                                   (progn
                                     (cond
                                      ((string-prefix-p "exited abnormally" event)
                                       (setq exit-status (process-exit-status p)))
                                      ((string= event "finished\n")
                                       (setq exit-status 0)))
                                     (cond
                                      (killed-by-user
                                       (pdd-reject task 'process-canceled context))
                                      ((and exit-status (/= exit-status 0))
                                       (pdd-reject task (format "Exit %d. %s" exit-status (buffer-string)) context))
                                      (t
                                       (pdd--with-restored-dynamic-context context
                                         (let ((res (cond ((eq as 'line) (funcall as-line-fn))
                                                          ((functionp as) (funcall as))
                                                          (t (buffer-string)))))
                                           (pdd-resolve task res exit-status))))))
                                 (when (buffer-live-p (current-buffer))
                                   (kill-buffer (current-buffer)))
                                 (ignore-errors (pdd-funcall fine (list proc))))))))
         :signal signal-fn
         (condition-case err
             (progn
               (pdd-log 'cmd "%s: %s %s" proc-name cmd-args proc-envs)
               (setq proc (make-process
                           :name proc-name
                           :command cmd-args
                           :buffer proc-buffer
                           :filter filter-fn
                           :sentinel sentinel-fn))
               (when init
                 (if (functionp init)
                     (pdd-funcall init (list proc))
                   (let* ((str (format "%s" init))
                          ;; tee and some same processes will hang when no newline append at last
                          ;; i don't know if there is better way to resolve this
                          (str (concat str (if (member program pdd--proc-send-need-newline) "\n"))))
                     (process-send-string proc str)
                     (process-send-eof proc)))))
           (error (pdd-reject task (format "Process creation failed: %s" err) context)))
         (setq it (pdd--wrap-task-handlers it done fail fine proc)))))))

;; Async/Await

(defun pdd--error-matches-spec-p (reason-data condition-spec)
  "Check if REASON-DATA matches CONDITION-SPEC for `condition-case'."
  (let ((error-symbol
         (when (and (consp reason-data) (symbolp (car reason-data)))
           (car reason-data))))
    (cond
     ((eq condition-spec 'error) t)
     ((not error-symbol) nil)
     ((symbolp condition-spec) (eq error-symbol condition-spec))
     ((consp condition-spec) (memq error-symbol condition-spec))
     (t nil))))

(defmacro pdd-async (&rest body)
  "Execute BODY asynchronously, allowing `await' for `pdd-task' results."
  (declare (indent 0) (debug t))
  (cl-labels
      ((find-innermost-await (form)
         (let (innermost-found innermost-task innermost-placeholder)
           (cl-labels
               ((walk (subform)
                  (unless innermost-found
                    (cond ((or (atom subform) (memq (car subform) '(quote function \`))) nil)
                          ((eq (car subform) 'await)
                           (let ((nested-await-found nil))
                             (cl-block nil
                               (dolist (arg (cdr subform))
                                 (when (find-innermost-await arg)
                                   (setq nested-await-found t)
                                   (cl-return))))
                             (unless nested-await-found
                               (setq innermost-found subform
                                     innermost-task (if (cddr subform)
                                                        `(pdd-all ,@(cdr subform))
                                                      (cadr subform))
                                     innermost-placeholder (gensym "--await-result-")))))
                          (t (mapc #'walk subform))))))
             (walk form))
           (when innermost-found
             (list innermost-found innermost-task innermost-placeholder))))

       (replace-innermost-await (form await)
         (let ((expr (car await)) (placeholder (caddr await)))
           (cl-labels
               ((walk (subform)
                  (cond ((eq subform expr) placeholder)
                        ((or (atom subform) (memq (car-safe subform) '(quote function \` await))) subform)
                        (t (cons (walk (car subform))
                                 (when (cdr subform) (mapcar #'walk (cdr subform))))))))
             (walk form))))

       (transform-expr (form)
         (if-let* ((await (find-innermost-await form)))
             `(:await ,(cadr await) :then (lambda (,(caddr await))
                                            ,(replace-innermost-await form await)))
           form))

       (transform-body (forms)
         (if (null forms) '(pdd-resolve nil)
           (let ((form1 (car forms)) (rest-forms (cdr forms)))
             (pcase (car-safe form1)
               ('let* (transform-let* (cadr form1) (append (cddr form1) rest-forms)))
               ('if (transform-if form1 rest-forms))
               ('condition-case (transform-condition-case form1 rest-forms))
               ('progn (transform-body (append (cdr form1) rest-forms)))
               (_ (transform-regular form1 rest-forms))))))

       (transform-regular (form1 rest-forms)
         (setq form1 (transform-expr form1))
         (if (eq (car-safe form1) :await)
             (let* ((task (plist-get form1 :await))
                    (then (plist-get form1 :then))
                    (placeholder (caadr then))
                    (body (caddr then)))
               `(pdd-then (pdd-task-ensure ,task)
                  (lambda (,placeholder) ,(transform-body (cons body rest-forms)))))
           `(condition-case err
                (pdd-then (pdd-task-ensure ,form1)
                  (lambda (_) ,(transform-body rest-forms)))
              (error (pdd-reject err)))))

       (transform-let* (bindings body-forms)
         (if (null bindings) (transform-body body-forms)
           (let* ((binding (car bindings))
                  (var (car binding))
                  (val-form (cadr binding))
                  (rest-bindings (cdr bindings))
                  (transformed-val (transform-expr val-form)))
             (if (eq (car-safe transformed-val) :await)
                 (let* ((task (plist-get transformed-val :await))
                        (then (plist-get transformed-val :then))
                        (placeholder (caadr then))
                        (body (caddr then)))
                   `(pdd-then (pdd-task-ensure ,task)
                      (lambda (,placeholder)
                        (pdd-then (pdd-task-ensure ,body)
                          (lambda (,var) ,(transform-let* rest-bindings body-forms))))))
               `(condition-case err
                    (let ((,var ,transformed-val))
                      ,(transform-let* rest-bindings body-forms))
                  (error (pdd-reject err)))))))

       (transform-if (if-form rest-forms)
         (let* ((condition (transform-expr (cadr if-form)))
                (then-form (caddr if-form))
                (else-form (cadddr if-form)))
           (if (eq (car-safe condition) :await)
               (let* ((task (plist-get condition :await))
                      (then (plist-get condition :then))
                      (placeholder (caadr then))
                      (body (caddr then)))
                 `(pdd-then (pdd-task-ensure ,task)
                    (lambda (,placeholder)
                      (pdd-then (pdd-task-ensure ,body)
                        (lambda (cond-result)
                          (if cond-result
                              ,(transform-body (cons then-form rest-forms))
                            ,(if else-form
                                 (transform-body (cons else-form rest-forms))
                               (transform-body rest-forms))))))))
             `(condition-case err
                  (if ,condition
                      ,(transform-body (cons then-form rest-forms))
                    ,(if else-form
                         (transform-body (cons else-form rest-forms))
                       (transform-body rest-forms)))
                (error (pdd-reject err))))))

       (transform-condition-case (cc-form rest-forms)
         (let* ((var (cadr cc-form))
                (protected-form (caddr cc-form))
                (handlers (cdddr cc-form))
                (transformed-protected-task (transform-body (list protected-form))))
           `(pdd-then ,transformed-protected-task
              (lambda (protected-result)
                ,(if (null rest-forms)
                     `(pdd-resolve protected-result)
                   (transform-body rest-forms)))
              (lambda (reason-data)
                (let ((,var reason-data))
                  (condition-case err
                      (cond ,@(mapcar
                               (lambda (handler)
                                 (let* ((condition-spec (car handler))
                                        (handler-body (cdr handler))
                                        (transformed-handler-chain (transform-body (append handler-body rest-forms))))
                                   `((pdd--error-matches-spec-p reason-data ',condition-spec)
                                     ,transformed-handler-chain)))
                               handlers)
                       (t (pdd-reject reason-data)))
                    (error (pdd-reject err)))))))))
    `(let ((pdd-default-sync nil)) ,(transform-body body))))

;; Cookie

(defclass pdd-cookie-jar ()
  ((cookies :initarg :cookies
            :initform nil
            :type list
            :documentation "Alist of (domain . cookie-list) where each cookie is a plist")
   (persist :initarg :persist
            :initform nil
            :type (or string null)
            :documentation "Location persist cookies to"))
  :documentation "Cookie jar for storing and managing HTTP cookies.")

(defun pdd-cookie-expired-p (cookie)
  "Check if COOKIE has expired."
  (let ((expires (plist-get cookie :expires))
        (max-age (plist-get cookie :max-age))
        (created-at (plist-get cookie :created-at)))
    (cond
     ((and created-at max-age)
      (time-less-p (time-add created-at (seconds-to-time max-age))
                   (current-time)))
     ((and expires (stringp expires))
      (time-less-p (date-to-time expires) (current-time))))))

(cl-defgeneric pdd-cookie-jar-get (jar domain &optional path secure)
  "Get cookies from JAR matching DOMAIN, PATH and SECURE flag."
  (:method ((jar pdd-cookie-jar) domain &optional path secure)
           (with-slots (cookies) jar
             (cl-loop
              for (cookie-domain . items) in cookies
              when (string-match-p (concat "\\.?" (regexp-quote domain) "$") cookie-domain)
              append (cl-loop
                      for cookie in items
                      when (and
                            (not (pdd-cookie-expired-p cookie))
                            (or (null path)
                                (string-prefix-p (or (plist-get cookie :path) "/") path))
                            (not (and (null secure) (plist-get cookie :secure))))
                      collect cookie)))))

(cl-defgeneric pdd-cookie-jar-put (jar domain cookie-list)
  "Add one or multiple cookies from COOKIE-LIST to the JAR for specified DOMAIN."
  (declare (indent 2))
  (:method ((jar pdd-cookie-jar) domain cookie-list)
           (with-slots (cookies) jar
             (dolist (cookie (if (plist-get cookie-list :name) (list cookie-list) cookie-list))
               (let ((items (assoc-string domain cookies)))
                 (if items
                     (setcdr items
                             (cl-remove-if
                              (lambda (item)
                                (or (null (plist-get item :name))
                                    (and (equal (plist-get item :name)
                                                (plist-get cookie :name))
                                         (equal (plist-get item :path)
                                                (plist-get cookie :path)))))
                              (cdr items)))
                   (setf items (cons domain nil) cookies (cons items cookies)))
                 (when (plist-get cookie :max-age)
                   (plist-put cookie :created-at (current-time)))
                 (setcdr items (cons cookie (cdr items)))))
             (pdd-cookie-jar-persist jar))))

(cl-defgeneric pdd-cookie-jar-persist (jar)
  "Save cookies to persistent FILE for JAR."
  (:method ((jar pdd-cookie-jar))
           (with-slots (cookies persist) jar
             (when (stringp persist)
               (condition-case err
                   (with-temp-file (setf persist (expand-file-name persist))
                     (let ((print-level nil) (print-length nil))
                       (when cookies
                         (pp (cl-loop for (domain . items) in cookies
                                      collect (cons domain (cl-remove-if #'pdd-cookie-expired-p items)))
                             (current-buffer)))
                       jar))
                 (error (user-error "Persist cookie failed. %s" err)))))))

(cl-defgeneric pdd-cookie-jar-load (jar &optional required)
  "Load cookies from persist file into the cookie JAR.
If REQUIRED is non-nil, raise error when persist file not found."
  (:method ((jar pdd-cookie-jar) &optional required)
           (with-slots (cookies persist) jar
             (when persist
               (when (or (not (stringp persist))
                         (not (file-writable-p (setf persist (expand-file-name persist))))
                         (and (file-exists-p persist)
                              (not (file-readable-p persist))))
                 (user-error "Cookie file `%s' is unavailable" persist))
               (if (file-exists-p persist)
                   (with-temp-buffer
                     (insert-file-contents-literally persist)
                     (unless (string-empty-p (buffer-substring (point-min) (point-max)))
                       (setf cookies (read (current-buffer)))))
                 (if required (user-error "Cookie file `%s' is not exist" persist)))
               jar))))

(cl-defgeneric pdd-cookie-jar-clear (jar &optional domain not-persist)
  "Clear cookies from JAR based on DOMAIN and expiration status.

If DOMAIN is:
- a string: delete only cookies matching this domain
- t: delete all cookies regardless of domain
- nil: only delete expired cookies (default)

When NOT-PERSIST is non-nil, changes are not saved to persistent storage.
If JAR is nil, operates on the default cookie jar."
  (:method ((jar pdd-cookie-jar) &optional domain not-persist)
           (with-slots (cookies) jar
             (when-let* ((jar (or jar pdd-default-cookie-jar)))
               (when cookies
                 (if (stringp domain)
                     (setf cookies (cl-remove-if
                                    (lambda (cookie) (string-match-p domain (car cookie)))
                                    cookies))
                   (if (eq domain t) (setf cookies nil)))
                 (setq cookies
                       (cl-loop for (domain . items) in cookies
                                for fresh = (cl-remove-if #'pdd-cookie-expired-p items)
                                when fresh collect (cons domain fresh)))
                 (unless not-persist (pdd-cookie-jar-persist jar)))
               jar)))
  (unless (or jar pdd-default-cookie-jar)
    (cl-call-next-method (or jar pdd-default-cookie-jar) domain not-persist)))

(cl-defmethod initialize-instance :after ((jar pdd-cookie-jar) &rest _)
  "Load or persist cookies if necessary."
  (with-slots (cookies persist) jar
    (when persist
      (if cookies
          (pdd-cookie-jar-persist jar)
        (pdd-cookie-jar-load jar)))))

;; Proxy

(cl-defgeneric pdd-proxy-vars (backend request)
  "Return proxy configs for REQUEST using BACKEND.")

;; Queue

(defclass pdd-queue ()
  ((limit :initarg :limit
          :initform 6
          :type integer
          :documentation "Max concurrent tasks")
   (running :type list :initform nil
            :documentation "Current running tasks")
   (waiting :type list :initform nil
            :documentation "Waiting list of (task . callback)")
   (fine :initarg :fine :type (or function null) :initform nil
         :documentation "Function to run when all tasks finished"))
  :documentation "Represent a queue to limit concurrent operations.")

(cl-defgeneric pdd-queue--signal-cancel-handler (queue task)
  "Create a signal handler specifically for TASK in QUEUE."
  (lambda (sig)
    (with-slots (waiting) queue
      (when (and (eq sig 'cancel) (assoc task waiting))
        (setf waiting (cl-remove task waiting :key #'car))))))

(cl-defgeneric pdd-queue-acquire (queue task callback)
  "Attempt to acquire the QUEUE for TASK.
Add to running or waiting list of QUEUE accordings.
CALLBACK is the function to run when acquire success."
  (with-slots (limit running waiting) queue
    (pdd-log 'queue "Acquire attempt: limit=%d, running=%d, waiting=%d" limit (length running) (length waiting))
    (if (< (length running) limit)
        (progn (funcall callback)
               (push task running)
               (pdd-log 'queue "Add to running list, len=%s" (length running))
               t)
      (let ((handler (pdd-queue--signal-cancel-handler queue task))
            (original-signal-fn (aref task 5)))
        (setf waiting (nconc waiting (list (cons task callback))))
        (aset task 5 (lambda (&optional signal-sym)
                       (funcall handler signal-sym)
                       (when original-signal-fn
                         (pdd-funcall original-signal-fn (list signal-sym)))))
        (pdd-log 'queue "Add to waiting list, len=%s" (length waiting))))))

(cl-defgeneric pdd-queue-release (queue task)
  "Release the TASK from QUEUE and run the next task from waiting list."
  (with-slots (limit running waiting fine) queue
    (pdd-log 'queue "Release attempt: limit=%d, running=%d, waiting=%d" limit (length running) (length waiting))
    (setf running (cl-remove task running))
    (when-let* ((item (pop waiting)))
      (funcall (cdr item))
      (push (car item) running))
    (when (and fine (null running) (null waiting))
      (pdd-funcall fine (list queue task)))))

;; Request

(defclass pdd-request ()
  ((url        :initarg :url         :type string)
   (method     :initarg :method      :type (or symbol string) :initform nil)
   (params     :initarg :params      :type (or string list)   :initform nil)
   (headers    :initarg :headers     :type list               :initform nil)
   (data       :initarg :data        :type (or function string list) :initform nil)
   (datas      :initform nil         :type (or string null))
   (binaryp    :initform nil         :type boolean)
   (as         :initarg :as          :type (or function null) :initform nil)
   (timeout    :initarg :timeout     :type (or number null)   :initform nil)
   (retry      :initarg :retry       :type (or number null)   :initform nil)
   (init       :initarg :init        :type (or function null) :initform nil)
   (filter     :initarg :filter      :type (or function null) :initform nil)
   (done       :initarg :done        :type (or function null) :initform nil)
   (fail       :initarg :fail        :type (or function null) :initform nil)
   (fine       :initarg :fine        :type (or function null) :initform nil)
   (sync       :initarg :sync)
   (buffer     :initarg :buffer      :initform nil)
   (backend    :initarg :backend     :type (or pdd-http-backend null))
   (cookie-jar :initarg :cookie-jar  :type (or pdd-cookie-jar function null) :initform nil)
   (proxy      :initarg :proxy       :type (or string list null) :initform nil)
   (queue      :initarg :queue       :type (or pdd-queue null) :initform nil)
   (process    :initarg :process     :initform nil)
   (abort-flag :initarg :abort-flag  :initform nil)
   (task       :initarg :task        :initform nil))
  "Abstract base class for HTTP request configs.")

(cl-defmethod pdd-transform-req-done ((request pdd-request))
  "Construct the :done callback handler for REQUEST."
  (with-slots (url done buffer task) request
    (let* ((args (pdd-function-arglist done))
           (request-ref request) (original-done done)
           (captured-buffer buffer) (captured-url url))
      (setf done
            `(lambda ,args
               (pdd-log 'done "enter")
               (unwind-protect
                   (condition-case err1
                       (with-current-buffer
                           (if (and (buffer-live-p ,captured-buffer) (cl-plusp ,(length args)))
                               ,captured-buffer
                             (current-buffer))
                         (prog1
                             (let ((result (,(or original-done 'identity) ,@args))
                                   (task (oref ,request-ref task)))
                               (if (not (pdd-task-p task))
                                   result
                                 (pdd-log 'task "TASK DONE:  %s" ,captured-url)
                                 (pdd-resolve task result ,request-ref)))
                           (pdd-log 'done "finished.")))
                     (error (setf (oref ,request-ref abort-flag) 'done)
                            (pdd-log 'done "error. %s" err1)
                            (funcall (oref ,request-ref fail) err1)))
                 (ignore-errors
                   (pdd-funcall (oref ,request-ref fine) (list ,request-ref)))))))))

(cl-defmethod pdd-transform-req-filter ((request pdd-request))
  "Construct the :filter callback handler for REQUEST."
  (with-slots (filter fail abort-flag) request
    (when-let* ((filter1 filter))
      (setf filter
            (lambda ()
              (if abort-flag
                  (pdd-log 'filter "skip filter (aborted).")
                (with-slots (abort-flag fail) request
                  (pdd-log 'filter "enter")
                  (condition-case err1
                      (if (zerop (length (help-function-arglist filter1)))
                          ;; with no argument
                          (funcall filter1)
                        ;; arguments: (&optional headers process request)
                        (let* ((headers (pdd-extract-http-headers))
                               (buffer (current-buffer))
                               (process (get-buffer-process buffer)))
                          (pdd-log 'filter "headers: %s" headers)
                          (pdd-funcall filter1 (list headers process request))))
                    (error (pdd-log 'filter "fail: %s" err1)
                           (setf abort-flag 'filter)
                           (funcall fail err1))))))))))

(cl-defmethod pdd-transform-req-fail ((request pdd-request))
  "Construct the :fail callback handler for REQUEST."
  (with-slots (retry fail fine abort-flag backend) request
    (setf fail
          (let ((fail1 fail)
                (fail-default pdd-default-error-handler)
                (context (pdd--capture-dynamic-context)))
            (lambda (err)
              (unless (memq abort-flag '(cancel abort))
                (pdd-log 'fail "%s | %s" err (or fail1 'None))
                ;; retry
                (if (and (cl-plusp retry) (funcall pdd-retry-condition err))
                    (progn
                      (if pdd-debug
                          (pdd-log 'fail "retrying (remains %d times)..." retry)
                        (let ((inhibit-message t))
                          (message "(%d) retring for %s..." retry (cadr err))))
                      (cl-decf retry)
                      (setf abort-flag nil)
                      (pdd backend request))
                  ;; really fail
                  (unwind-protect
                      (condition-case err1
                          (with-slots (url task) request
                            (cond ; error -> :fail -> task chain -> on-rejected | default handler
                             ((pdd-task-p task)
                              (when fail1
                                (pdd-log 'fail "calling user :fail callback")
                                (aset task 7 t) ; set inhibit-default-rejection-p flag
                                (ignore-errors
                                  (pdd-funcall fail1 (list (cadr err) (car-safe (cddr err)) err request))))
                              (pdd-log 'fail "reject error to task")
                              (pdd-log 'task "TASK FAIL:  %s" url)
                              (pdd-reject task err context))
                             (fail1
                              (pdd-log 'fail "display error with: fail callback.")
                              (pdd-funcall fail1 (list (cadr err) (car-safe (cddr err)) err request)))
                             (fail-default
                              (pdd-log 'fail "display error with: default error handler")
                              (pdd-funcall fail-default (list err request)))))
                        (error (pdd-log 'fail "oooop, error occurs when display error.")
                               (message "Oooop, error in error handling: %s" err1)))
                    ;; finally
                    (ignore-errors (pdd-funcall fine (list request)))))))))))

(cl-defmethod pdd-transform-req-headers ((request pdd-request))
  "Transform headers with stringfy and abbrev replacement in REQUEST."
  (with-slots (headers) request
    (setf headers
          (cl-loop
           with stringfy = (lambda (p) (cons (format "%s" (car p))
                                             (format "%s" (cdr p))))
           for item in headers for v = nil
           if (null item) do (ignore)
           if (setq v (and (symbolp item)
                           (pdd-with-common-cache (list 'rewrite item)
                             (alist-get item pdd-header-rewrite-rules))))
           collect (funcall stringfy v)
           else if (setq v (and (consp item)
                                (symbolp (car item))
                                (or (null (cdr item)) (car-safe (cdr item)))
                                (pdd-with-common-cache (list 'rewrite item)
                                  (alist-get (car item) pdd-header-rewrite-rules))))
           collect (funcall stringfy (cons (car v)
                                           (if (cdr item)
                                               (apply #'format (cdr v) (cdr item))
                                             (cdr v))))
           else if (cdr item)
           collect (funcall stringfy item)))))

(cl-defmethod pdd-transform-req-cookies ((request pdd-request))
  "Add cookies from cookie jar to REQUEST headers."
  (with-slots (headers url cookie-jar) request
    (let ((jar (or cookie-jar pdd-default-cookie-jar)))
      (when (functionp jar)
        (setq jar (pdd-funcall jar (list request))))
      (when (setf cookie-jar jar)
        (let* ((url-obj (pdd-generic-parse-url url))
               (domain (url-host url-obj))
               (path (url-filename url-obj))
               (secure (equal "https" (url-type url-obj))))
          (if (zerop (length path)) (setq path "/"))
          (when-let* ((cookies (pdd-cookie-jar-get cookie-jar domain path secure)))
            (pdd-log 'cookies "%s" cookies)
            (push (cons "Cookie"
                        (mapconcat
                         (lambda (c)
                           (format "%s=%s" (plist-get c :name) (plist-get c :value)))
                         cookies "; "))
                  headers)))))))

(cl-defmethod pdd-transform-req-data ((request pdd-request))
  "Serialize data to raw string for REQUEST."
  (with-slots (headers data datas binaryp) request
    (setf datas
          (if (functionp data) ; Wrap data in a function can avoid be converted
              (format "%s" (pdd-funcall data (list headers)))
            (if (atom data) ; Never modify the Content-Type when data is atom/string
                (and data (format "%s" data))
              (let ((ct (alist-get "Content-Type" headers nil nil #'pdd-string-iequal)))
                (cond ((string-match-p "/json" (or ct ""))
                       (setf binaryp t)
                       (encode-coding-string (pdd-object-to-string 'json data) 'utf-8))
                      ((cl-some (lambda (x) (consp (cdr x))) data)
                       (setf binaryp t)
                       (setf (alist-get "Content-Type" headers nil nil #'pdd-string-iequal)
                             (concat "multipart/form-data; boundary=" pdd-multipart-boundary))
                       (pdd-format-formdata data))
                      (t
                       (unless ct
                         (setf (alist-get "Content-Type" headers nil nil #'pdd-string-iequal)
                               "application/x-www-form-urlencoded"))
                       (pdd-object-to-string 'query data)))))))))

(cl-defmethod pdd-transform-req-proxy ((request pdd-request))
  "Parse proxy setting for current REQUEST."
  (let* ((backend (oref request backend))
         (proxy (or (oref request proxy) (oref backend proxy) pdd-default-proxy)))
    (when (functionp proxy)
      (setq proxy (pdd-funcall proxy (list request))))
    (when (stringp proxy)
      (condition-case nil
          (setq proxy (pdd-parse-proxy-url proxy))
        (error (user-error "Make sure proxy url is correct: %s" proxy))))
    (when proxy
      (unless (and (plist-get proxy :type) (plist-get proxy :host) (plist-get proxy :port))
        (user-error "Invalid proxy found"))
      (when (and (plist-get proxy :user)
                 (not (plist-get proxy :pass)))
        (require 'auth-source-pass)
        (let* ((host (plist-get proxy :host))
               (user (plist-get proxy :user))
               (port (plist-get proxy :port))
               (auths (or (auth-source-search :host host :user user :port port)
                          (auth-source-search :host host :user user)))
               (pass (plist-get 'secure (car auths))))
          (when (functionp pass)
            (setq pass (funcall pass)))
          (if pass (plist-put proxy :pass pass))))
      (oset request proxy proxy))))

(cl-defmethod pdd-transform-req-finally ((request pdd-request))
  "Other changes should be made for REQUEST."
  (with-slots (headers datas binaryp backend) request
    (unless (assoc "User-Agent" headers #'pdd-string-iequal)
      (push `("User-Agent" . ,(or (oref backend user-agent) pdd-user-agent)) headers))
    (when (and (not binaryp) datas)
      (setf binaryp (not (multibyte-string-p datas))))))

(cl-defmethod initialize-instance :after ((request pdd-request) &rest _)
  "Initialize the configs for REQUEST."
  (pdd-log 'req "req:init...")
  (with-slots (url method params headers data timeout retry sync init done filter abort-flag buffer backend task queue) request
    (when (and pdd-base-url (string-prefix-p "/" url))
      (setf url (concat pdd-base-url url)))
    (when params
      (setf url (pdd-gen-url-with-params url params)))
    ;; make such keywords can be dynamically bound
    (unless headers (setf headers pdd-default-headers))
    (unless data (setf data pdd-default-data))
    (unless done (setf done pdd-default-done))
    (unless filter (setf filter pdd-default-filter))
    (unless timeout (setf timeout pdd-default-timeout))
    (unless retry (setf retry pdd-default-retry))
    ;; init other slots
    (unless (slot-boundp request 'sync)
      (setf sync (if (eq pdd-default-sync 'unset)
                     (if done nil t) pdd-default-sync)))
    (unless method (setf method (if data 'post 'get)))
    (unless buffer (setf buffer (current-buffer)))
    (unless sync
      ;; create task for asynchronous request
      (setf task
            (pdd-with-new-task
             :signal (lambda ()
                       (pdd-log 'signal "cancel: %s" url)
                       (unless abort-flag (setf abort-flag 'cancel)))))
      ;; deal with queue
      (when (setf queue (or queue pdd-default-queue))
        (pdd-then task
          (lambda (&rest _)
            (pdd-log 'queue "Task %s fulfilled, releasing %s" task queue)
            (pdd-queue-release queue task))
          (lambda (&rest _)
            (pdd-log 'queue "Task %s rejected, releasing %s" task queue)
            (pdd-queue-release queue task)))))
    ;; run all of the installed transformers with request
    (cl-loop for transformer in (pdd-request-transformers backend)
             do (pdd-log 'req (symbol-name transformer))
             do (funcall transformer request))))

(cl-defgeneric pdd-make-request (backend &rest _arg)
  "Instance request object for BACKEND."
  (:method ((backend pdd-http-backend) &rest args)
           (apply #'pdd-request `(:backend ,backend :url ,@args))))

;; Response

(defvar-local pdd-resp-mark nil)
(defvar-local pdd-resp-body nil)
(defvar-local pdd-resp-headers nil)
(defvar-local pdd-resp-status nil)
(defvar-local pdd-resp-version nil)

(cl-defmethod pdd-transform-resp-init (_request)
  "The most first check, if no problems clean newlines and set `pdd-resp-mark'."
  (widen) ; in case that the buffer is narrowed
  (goto-char (point-min))
  (unless (re-search-forward "\n\n\\|\r\n\r\n" nil t)
    (user-error "Unable find end of headers"))
  (setq pdd-resp-mark (point-marker))
  (save-excursion ; Clean the ^M in headers
    (while (search-forward "\r" pdd-resp-mark :noerror)
      (replace-match ""))))

(cl-defmethod pdd-transform-resp-headers (_request)
  "Extract status line and headers."
  (goto-char (point-min))
  (skip-chars-forward " \t\n")
  (skip-chars-forward "/HPT")
  (setq pdd-resp-version (buffer-substring
                          (point) (progn (skip-chars-forward "0-9.") (point))))
  (setq pdd-resp-status (read (current-buffer)))
  (setq pdd-resp-headers (pdd-extract-http-headers))
  (unless (and pdd-resp-version pdd-resp-status pdd-resp-headers)
    (pdd-log 'resp-error "%s" (buffer-string))
    (user-error "Maybe something wrong with the response content")))

(cl-defmethod pdd-transform-resp-cookies (request)
  "Save cookies from response to cookie jar for REQUEST."
  (with-slots (cookie-jar url) request
    (when (and cookie-jar pdd-resp-headers)
      (cl-loop with domain = (or (url-host (pdd-generic-parse-url url)) "")
               for (k . v) in pdd-resp-headers
               if (eq k 'set-cookie) do
               (when-let* ((cookie (pdd-parse-set-cookie v t)))
                 (pdd-cookie-jar-put cookie-jar (or (plist-get cookie :domain) domain) cookie)))
      (pdd-cookie-jar-clear cookie-jar))))

(cl-defmethod pdd-transform-resp-decode (_request)
  "Decoding buffer automatically."
  (let* ((content-type (alist-get 'content-type pdd-resp-headers))
         (binaryp (pdd-binary-type-p content-type))
         (charset (and (not binaryp) (pdd-detect-charset content-type))))
    (set-buffer-multibyte (not binaryp))
    (when charset
      (decode-coding-region pdd-resp-mark (point-max) charset))))

(cl-defmethod pdd-transform-resp-body (request)
  "Convert response body as `pdd-resp-body' for REQUEST."
  (with-slots (as url) request
    (setq pdd-resp-body (buffer-substring pdd-resp-mark (point-max)))
    (pdd-log 'resp "raw: %s" pdd-resp-body)
    (setq pdd-resp-body
          (if (functionp as)
              (pdd-funcall as (list pdd-resp-body pdd-resp-headers))
            (let* ((ct (alist-get 'content-type pdd-resp-headers))
                   (type (cond ((string-match-p "/json" ct) 'json)
                               (t (intern (car (split-string ct "[; ]")))))))
              (pdd-string-to-object type pdd-resp-body))))))

(cl-defmethod pdd-transform-response (request)
  "Run all response transformers for REQUEST to get the results."
  (if (oref request abort-flag)
      (pdd-log 'resp "skip response (aborted).")
    (cl-loop for transformer in (pdd-response-transformers (oref request backend))
             do (pdd-log 'resp (symbol-name transformer))
             do (funcall transformer request))
    (list pdd-resp-body pdd-resp-headers
          pdd-resp-status pdd-resp-version request)))

;; Entrance

(cl-defgeneric pdd (backend url &rest _args &key
                            method
                            params
                            headers
                            data
                            as
                            init
                            filter
                            done
                            fail
                            fine
                            sync
                            timeout
                            retry
                            proxy
                            queue
                            &allow-other-keys)
  "Send request using the specified BACKEND.

This is a generic function with implementations provided by backend classes.

The documentation below is mainly described for the general http backend.

Parameters:
  BACKEND  - Backend instance
  URL      - Target URL (string)

Keyword Arguments:
  :METHOD  - HTTP method (symbol, e.g. `get, `post, `put), defaults to `get
  :PARAMS  - URL query parameters, accepts:
             * String - appended directly to URL
             * Alist - converted to key=value&... format
  :HEADERS - Request headers, supports formats:
             * Regular: (\"Header-Name\" . \"value\")
             * Abbrev symbols: json, bear (see `pdd-header-rewrite-rules')
             * Parameterized abbrevs: (bear \"token\")
  :DATA    - Request body data, accepts:
             * String - sent directly
             * Alist - converted to formdata or JSON based on Content-Type
             * File uploads: ((key filepath))
  :INIT    - Function called before the request is fired by backend:
             (lambda (&optional request))
  :FILTER  - Filter function called during data reception, signature:
             (lambda (&optional headers process request))
  :AS      - Response transformer function for raw response data, signature:
             (lambda (data &optional headers))
  :DONE    - Success callback, signature:
             (lambda (&optional body headers status-code http-version request))
  :FAIL    - Failure callback, signature:
             (&optional error-message http-status-code error-object request)
  :FINE    - Final callback (always called), signature:
             (&optional request-instance)
  :SYNC    - Whether to execute synchronously (boolean)
  :TIMEOUT - Timeout in seconds
  :RETRY   - Number of retry attempts on timeout
  :PROXY   - Proxy used by current http request
  :QUEUE   - Semaphore object used to limit concurrency (async only)

Returns:
  Response data in sync mode, task object in async mode.

Examples:
  ;; Simple GET request
  (pdd some-backend \"https://api.example.com\")

  ;; POST JSON data
  (pdd some-backend \"https://api.example.com/api\"
       :headers \\='(json)
       :data \\='((key . \"value\")))

  ;; Multipart request with file upload
  (pdd some-backend \"https://api.example.com/upload\"
       :data \\='((file \"path/to/file\")))

  ;; Async request with callbacks
  (pdd some-backend \"https://api.example.com/data\"
       :done (lambda (data) (message \"Got: %S\" data))
       :fail (lambda (err) (message \"Error: %S\" err)))."
  (declare (indent 1)))

(cl-defmethod pdd :around ((backend pdd-http-backend) &rest args)
  "The common logics before or after the http request for BACKEND.
ARGS should a request instances or keywords to build the request."
  (let ((request (if (cl-typep (car args) 'pdd-request)
                     (car args)
                   (apply #'pdd-make-request backend args))))
    (with-slots (sync init task process queue) request
      (pdd-log 'req "pdd:around...")
      (if (or sync (null queue) (memq task (oref queue running)))
          (let ((result (progn (if init (pdd-funcall init (list request)))
                               (cl-call-next-method backend :request request))))
            (if sync result (setf process result) task))
        (let ((callback (lambda ()
                          (if init (pdd-funcall init (list request)))
                          (setf process (cl-call-next-method backend :request request)))))
          (pdd-queue-acquire queue task callback))))))

(cl-defgeneric pdd-request-transformers (_backend)
  "Return the request transformers will be used by BACKEND."
  pdd-default-request-transformers)

(cl-defgeneric pdd-response-transformers (_backend)
  "Return the response transformers will be used by BACKEND."
  pdd-default-response-transformers)


;;; Implement for url.el

(require 'socks)
(require 'gnutls)

(defclass pdd-url-backend (pdd-http-backend) ()
  :documentation "Http Backend implemented using `url.el'.")

(defvar url-http-content-type)
(defvar url-http-end-of-headers)
(defvar url-http-transfer-encoding)
(defvar url-http-response-status)
(defvar url-http-response-version)

(defvar socks-server)
(defvar socks-username)
(defvar socks-password)
(defvar tls-params)

(defvar pdd-url-extra-filter nil)

(cl-defmethod pdd-proxy-vars ((_ pdd-url-backend) (request pdd-request))
  "Serialize proxy config for url REQUEST."
  (with-slots (proxy) request
    (when proxy
      (cl-destructuring-bind (&key type host port user pass) proxy
        (if (string-prefix-p "sock" (symbol-name type))
            ;; case of using socks proxy
            (let ((version (substring (symbol-name type) 5)))
              (cond
               ((member version '("4" "5"))
                (setq version (string-to-number version)))
               ((equal version "4a")
                (setq version '4a))
               (t (user-error "Maybe invalid socket proxy setup, url.el only support socks4, socks5 and socks4a")))
              (list :server (list "Default server" host port version)
                    :user user :pass pass))
          ;; case of using http proxy, used by `url-proxy-locator'
          (format "%s%s:%s"
                  (if (and user pass) (format "%s:%s@" user pass) "")
                  host port))))))

(cl-defmethod pdd-transform-error ((_ pdd-url-backend) (request pdd-request) status)
  "Extract error object from callback STATUS for REQUEST."
  (with-slots (abort-flag) request
    (cond ((null status)
           (setf abort-flag 'conn)
           `(http "Maybe something wrong with network" 400))
          ((or (null url-http-end-of-headers) (= 1 (point-max)))
           (setf abort-flag 'conn)
           `(http "Response unusual empty content" 417))
          ((plist-get status :error)
           (setf abort-flag 'resp)
           (let* ((err (plist-get status :error))
                  (code (caddr err)))
             `(,(car err) ,(pdd-http-code-text code) ,code))))))

(defun pdd-url-http-extra-filter (beg end len)
  "Call `pdd-url-extra-filter'.  BEG, END and LEN see `after-change-functions'."
  (when (and pdd-url-extra-filter (bound-and-true-p url-http-end-of-headers)
             (if (equal url-http-transfer-encoding "chunked") (= beg end) ; when delete
               (= len 0))) ; when insert
    (save-excursion
      (save-restriction
        (narrow-to-region url-http-end-of-headers (point-max))
        (funcall pdd-url-extra-filter)))))

(cl-defmethod pdd ((backend pdd-url-backend) &key request)
  "Send REQUEST with url.el as BACKEND."
  (with-slots (url method headers datas binaryp resp filter done fail timeout sync abort-flag) request
    ;; setup proxy
    (let* ((proxy (pdd-proxy-vars backend request))
           (socks-server (if proxy nil socks-server))
           (socks-username (if proxy nil socks-username))
           (socks-password (if proxy nil socks-password))
           (origin-url-https (symbol-function 'url-https))
           (origin-socks-open-network-stream (symbol-function 'socks-open-network-stream))
           (url-proxy-locator (if proxy (lambda (&rest _) "DIRECT") url-proxy-locator)))
      ;; It's not an easy thing to make url.el support tls over socks proxy
      ;; - [bug#13833] https://lists.nongnu.org/archive/html/bug-gnu-emacs/2025-03/msg01757.html
      ;; - [bug#53941] https://lists.gnu.org/archive/html/bug-gnu-emacs/2024-09/msg00836.html
      ;; Patch like below looks wired, but seems it makes proxy work well, both http and socks proxy
      (cl-letf (((symbol-function 'url-https)
                 (if (and proxy (consp proxy))
                     (lambda (url callback cbargs)
                       (url-http url callback cbargs nil 'socks))
                   origin-url-https))
                ((symbol-function 'socks-open-network-stream)
                 (if (and proxy (consp proxy))
                     (lambda (name buffer host service)
                       (let ((proc (funcall origin-socks-open-network-stream name buffer host service)))
                         (if (string-prefix-p "https" url)
                             (let ((tls-params (list :hostname host :verify-error nil)))
                               (gnutls-negotiate :process proc :type 'gnutls-x509pki :hostname host))
                           proc)))
                   origin-socks-open-network-stream)))
        (cond ((consp proxy)
               (setq socks-server (plist-get proxy :server)
                     socks-username (plist-get proxy :user)
                     socks-password (plist-get proxy :pass)))
              ((stringp proxy)
               (setq url-proxy-locator (lambda (&rest _) (concat "PROXY " proxy)))))
        ;; start url-retrive
        (let* ((url-request-method (string-to-unibyte (upcase (format "%s" method))))
               (url-request-data datas)
               (url-user-agent (alist-get "user-agent" headers nil nil #'pdd-string-iequal))
               (url-request-extra-headers (assoc-delete-all "user-agent" headers #'pdd-string-iequal))
               (url-mime-encoding-string "identity")
               timer buffer-data data-buffer
               (callback (lambda (status)
                           (pdd-log 'url-backend "callback.")
                           (ignore-errors (cancel-timer timer))
                           (setq data-buffer (current-buffer))
                           (remove-hook 'after-change-functions #'pdd-url-http-extra-filter t)
                           (if abort-flag
                               (progn (pdd-log 'url-backend "skip done (aborted).")
                                      (funcall fail nil))
                             (unwind-protect
                                 (condition-case err1
                                     (if-let* ((err (pdd-transform-error backend request status)))
                                         (progn (pdd-log 'url-backend "before fail")
                                                (funcall fail err))
                                       (pdd-log 'url-backend "before done")
                                       (setq buffer-data (pdd-funcall done (pdd-transform-response request))))
                                   (error (funcall fail err1)))
                               (unless sync (kill-buffer data-buffer))))))
               (proc-buffer (url-retrieve url callback nil t t))
               (process (get-buffer-process proc-buffer)))
          ;; log
          (pdd-log 'url-backend
            "%s %s"             url-request-method url
            "HEADER: %S"        url-request-extra-headers
            "DATA: %s"          url-request-data
            "BINARY: %s"        binaryp
            "Proxy: %S"         proxy
            "User Agent: %s"    url-user-agent
            "MIME Encoding: %s" url-mime-encoding-string)
          ;; :filter support via hook
          (when (and filter (buffer-live-p proc-buffer))
            (with-current-buffer proc-buffer
              (setq-local pdd-url-extra-filter filter)
              (add-hook 'after-change-functions #'pdd-url-http-extra-filter nil t)))
          ;; :timeout support via timer
          (when (numberp timeout)
            (let ((timer-callback
                   (lambda ()
                     (pdd-log 'timer "kill timeout.")
                     (unless data-buffer
                       (ignore-errors (stop-process process))
                       (ignore-errors
                         (with-current-buffer proc-buffer
                           (erase-buffer)
                           (setq-local url-http-end-of-headers 30)
                           (insert "HTTP/1.1 408 Operation timeout")))
                       (ignore-errors (delete-process process))))))
              (setq timer (run-with-timer timeout nil timer-callback))))
          (if (and sync proc-buffer)
              ;; copy from `url-retrieve-synchronously'
              (catch 'pdd-done
                (when-let* ((redirect-buffer (buffer-local-value 'url-redirect-buffer proc-buffer)))
                  (unless (eq redirect-buffer proc-buffer)
                    (let (kill-buffer-query-functions)
                      (kill-buffer proc-buffer))
                    (setq proc-buffer redirect-buffer)))
                (when-let* ((proc (get-buffer-process proc-buffer)))
                  (when (memq (process-status proc) '(closed exit signal failed))
                    (unless data-buffer
		              (throw 'pdd-done 'exception))))
                (with-local-quit
                  (while (and (process-live-p process) (not abort-flag) (not data-buffer))
                    (accept-process-output nil 0.05)))
                buffer-data)
            process))))))


;;; Implement for plz.el

(defclass pdd-curl-backend (pdd-http-backend)
  ((extra-args
    :initarg :args
    :type list
    :documentation "Extra arguments passed to curl program."))
  :documentation "Http Backend implemented using `plz.el'.")

(defvar plz-curl-program)
(defvar plz-curl-default-args)
(defvar plz-http-end-of-headers-regexp)
(defvar plz-http-response-status-line-regexp)

(declare-function plz "ext:plz.el" t t)
(declare-function plz-error-p "ext:plz.el" t t)
(declare-function plz-error-message "ext:plz.el" t t)
(declare-function plz-error-curl-error "ext:plz.el" t t)
(declare-function plz-error-response "ext:plz.el" t t)
(declare-function plz-response-status "ext:plz.el" t t)
(declare-function plz-response-body "ext:plz.el" t t)

(cl-defmethod pdd :before ((_ pdd-curl-backend) &rest _)
  "Check if `plz.el' is available."
  (unless (and (require 'plz nil t) (executable-find plz-curl-program))
    (error "You should have `plz.el' and `curl' installed before using `pdd-curl-backend'")))

(cl-defmethod pdd-proxy-vars ((_ pdd-curl-backend) (request pdd-request))
  "Return proxy configs for plz REQUEST."
  (with-slots (proxy) request
    (when proxy
      (cl-destructuring-bind (&key type host port user pass) proxy
        `("--proxy" ,(format "%s://%s:%d" type host port)
          ,@(when (and user pass)
              `("--proxy-user" ,(format "%s:%s" user pass))))))))

(cl-defmethod pdd-transform-error ((_ pdd-curl-backend) (_ pdd-request) error)
  "Hacky, but try to unify the ERROR data format with url.el."
  (when (and (consp error) (memq (car error) '(plz-http-error plz-curl-error)))
    (setq error (caddr error)))
  (if (not (plz-error-p error)) error
    (if-let* ((display (plz-error-message error)))
        (list 'plz-error display)
      (if-let* ((curl (plz-error-curl-error error)))
          (list 'plz-error
                (concat (format "%s" (or (cdr curl) (car curl)))
                        (pcase (car curl)
                          (2 (when (memq system-type '(cygwin windows-nt ms-dos))
                               "\n\nTry to install curl and specify the program like this to solve the problem:\n
  (setq plz-curl-program \"c:/msys64/usr/bin/curl.exe\")\n
Or switch http backend to `pdd-url-backend' instead:\n
  (setq pdd-default-backend (pdd-url-backend))")))))
        (if-let* ((res (plz-error-response error))
                  (code (plz-response-status res)))
            (list 'error (pdd-http-code-text code) code)
          error)))))

(cl-defmethod pdd ((backend pdd-curl-backend) &key request)
  "Send REQUEST with plz as BACKEND."
  (with-slots (url method headers datas binaryp resp filter done fail timeout sync abort-flag) request
    (let* ((tag (eieio-object-class backend))
           (proxy (pdd-proxy-vars backend request))
           (plz-curl-default-args
            (if proxy (append proxy plz-curl-default-args) plz-curl-default-args))
           (filter-fn
            (when filter
              (lambda (proc string)
                (with-current-buffer (process-buffer proc)
                  (save-excursion
                    (goto-char (point-max))
                    (save-excursion (insert string))
                    (when (re-search-forward plz-http-end-of-headers-regexp nil t)
                      (save-restriction
                        ;; it's better to provide a narrowed buffer to :filter
                        (narrow-to-region (point) (point-max))
                        (funcall filter))))))))
           (results (lambda ()
                      (pdd-log tag "before resp")
                      (pdd-transform-response request))))
      ;; log
      (pdd-log tag
        "%s"          url
        "HEADER: %S"  headers
        "DATA: %s"    datas
        "BINARY: %s"  binaryp
        "EXTRA: %S"   plz-curl-default-args)
      ;; sync
      (if sync
          (condition-case err
              (let ((res (plz method url
                           :headers headers
                           :body datas
                           :body-type (if binaryp 'binary 'text)
                           :decode nil
                           :as results
                           :filter filter-fn
                           :then 'sync
                           :timeout timeout)))
                (if abort-flag
                    (pdd-log tag "skip done (aborted).")
                  (pdd-log tag "before done")
                  (pdd-funcall done res)))
            (error
             (pdd-log tag "before fail")
             (funcall fail (pdd-transform-error backend request err))))
        ;; async
        (plz method url
          :headers headers
          :body datas
          :body-type (if binaryp 'binary 'text)
          :decode nil
          :as results
          :filter filter-fn
          :then (lambda (res)
                  (if abort-flag
                      (pdd-log tag "skip done (aborted).")
                    (pdd-log tag "before done")
                    (pdd-funcall done res)))
          :else (lambda (err)
                  (pdd-log tag "before fail")
                  (funcall fail (pdd-transform-error backend request err)))
          :timeout timeout)))))



(defvar pdd-default-backend
  (if (and (require 'plz nil t) (executable-find plz-curl-program))
      (pdd-curl-backend)
    (pdd-url-backend))
  "Default backend used by `pdd' for HTTP requests.

The value can be either:
- A instance of function `pdd-http-backend', or
- A function that returns such a instance.

When the value is a function, it will be called with:
- Either just the URL (string), or
- Both URL and HTTP method (symbol)

The function will be evaluated dynamically each time `pdd' is invoked,
allowing for runtime backend selection based on request parameters.")

(defun pdd-ensure-default-backend (args)
  "Pursue the value of variable `pdd-default-backend' if it is a function.
ARGS should be the arguments of function `pdd'."
  (if (functionp pdd-default-backend)
      (pdd-funcall pdd-default-backend
        (list (car args) (intern-soft
                          (or (plist-get (cdr args) :method)
                              (if (plist-get (cdr args) :data) 'post 'get)))))
    pdd-default-backend))

(defun pdd-complete-absent-keywords (&rest args)
  "Add the keywords absent for ARGS used by function `pdd'."
  (let* ((pos (or (cl-position-if #'keywordp args) (length args)))
         (fst (cl-subseq args 0 pos))
         (lst (cl-subseq args pos))
         (take (lambda (fn) (if-let* ((p (cl-position-if fn fst))) (pop (nthcdr p fst)))))
         (url (funcall take (lambda (arg) (and (stringp arg) (string-match-p "^\\(http\\|/\\)" arg)))))
         (method (funcall take (lambda (arg) (memq arg '(get post put patch delete head options trace connect)))))
         (done (funcall take #'functionp))
         (params-or-data (car-safe fst))
         params data)
    (cl-assert url nil "Url is required")
    (when params-or-data
      (if (eq 'get (or method (plist-get lst :method)))
          (setq params params-or-data)
        (setq data params-or-data)))
    `(,url ,@(if method `(:method ,method)) ,@(if done `(:done ,done))
           ,@(if params `(:params ,params)) ,@(if data `(:data ,data)) ,@lst)))

;;;###autoload
(cl-defmethod pdd (&rest args)
  "Send an HTTP request using the `pdd-default-backend'.

This is a convenience method that uses the default backend instead of
requiring one to be specified explicitly.

ARGS should be a plist where the first argument is the URL (string).
Other supported arguments are the same as the generic `pdd' method."
  (let* ((args (apply #'pdd-complete-absent-keywords args))
         (backend (pdd-ensure-default-backend args)))
    (unless (and backend (eieio-object-p backend) (object-of-class-p backend 'pdd-backend))
      (user-error "Make sure `pdd-default-backend' is available.  eg:\n
(setq pdd-default-backend (pdd-url-backend))\n\n\n"))
    (apply #'pdd backend args)))

(provide 'pdd)

;;; pdd.el ends here
