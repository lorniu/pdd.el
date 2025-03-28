;;; pdd.el --- HTTP Library -*- lexical-binding: t -*-

;; Copyright (C) 2025 lorniu <lorniu@gmail.com>

;; Author: lorniu <lorniu@gmail.com>
;; URL: https://github.com/lorniu/pdd.el
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "29.1"))
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
;; A versatile HTTP library that provides a unified interface making http
;; requests across multiple backend implementations easily. It is designed
;; for simplicity, flexibility and cross-platform compatibility.
;;
;;  - Choose between built-in `url.el' or high-performance `curl' backends. It
;;    gracefully falls back to `url.el' when `curl' is unavailable without
;;    requiring code changes.
;;  - Rich feature set including multipart uploads, streaming support,
;;    cookie-jar support, intercepters support, automatic retry strategies,
;;    and smart data conversion. Enhances `url.el' to support all these
;;    capabilities and works well enough.
;;  - Minimalist yet intuitive API that works consistently across backends.
;;    Features like variadic callbacks and header abbreviation rules help
;;    you accomplish more with less code.
;;  - Extensible architecture makes it easy to add new backends.
;;
;;      (pdd "https://httpbin.org/post"
;;        :headers '((bear "hello world"))
;;        :params '((name . "jerry") (age . 9))
;;        :data '((key . "value") (file1 "~/aaa.jpg"))
;;        :done (lambda (json) (alist-get 'file json)))
;;
;; See README.md of https://github.com/lorniu/pdd.el for more


;;; Code:

(require 'cl-lib)
(require 'url-http)
(require 'eieio)
(require 'json)
(require 'help)

(defgroup pdd nil
  "HTTP Library Adapter."
  :group 'network
  :prefix 'pdd-)

(defcustom pdd-debug nil
  "Debug flag."
  :type 'boolean)

(defcustom pdd-user-agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.75 Safari/537.36"
  "Default user agent used by request."
  :type 'string)

(defcustom pdd-max-retry 1
  "Default retry times when request timeout."
  :type 'integer)

(defconst pdd-multipart-boundary (format "pdd-boundary-%x%x=" (random) (random))
  "A string used as multipart boundary.")

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

(defvar url-http-codes)

(defun pdd-log (tag &rest args)
  "Output log to *Messages* buffer using syntax of `message'.
TAG usually is the name of current http backend.  ARGS should be fmt and
rest arguments."
  (declare (indent 1))
  (when pdd-debug
    (cl-loop with sub = nil
             with fmt = (format "[%s] " (or tag "pdd"))
             with msg = (lambda (args)
                          (setq args (nreverse args))
                          (apply #'message (concat fmt (car args)) (cdr args)))
             for el in args
             if (and (stringp el) (cl-find ?% el))
             do (progn (if sub (funcall msg sub)) (setq sub (list el)))
             else do (push el sub)
             finally (funcall msg sub))))

(defun pdd-detect-charset (content-type)
  "Detect charset from CONTENT-TYPE header."
  (when content-type
    (let ((case-fold-search t))
      (if (string-match "charset=\\s-*\\([^; \t\n\r]+\\)" (format "%s" content-type))
          (intern (downcase (match-string 1 content-type)))
        'utf-8))))

(defun pdd-binary-type-p (content-type)
  "Check if current CONTENT-TYPE represents binary data."
  (when content-type
    (cl-destructuring-bind (mime sub)
        (string-split content-type "/" nil "[ \n\r\t]")
      (not (or (equal mime "text")
               (and (equal mime "application")
                    (string-match-p
                     (concat "json\\|xml\\|yaml\\|font"
                             "\\|javascript\\|php\\|form-urlencoded")
                     sub)))))))

(defun pdd-format-params (alist)
  "Convert an ALIST of parameters into a URL-encoded query string."
  (mapconcat (lambda (arg)
               (format "%s=%s"
                       (url-hexify-string (format "%s" (car arg)))
                       (url-hexify-string (format "%s" (or (cdr arg) 1)))))
             (delq nil alist) "&"))

(defun pdd-gen-url-with-params (url params)
  "Generate a URL by appending PARAMS to URL with proper query string syntax."
  (if-let* ((ps (if (consp params) (pdd-format-params params) params)))
      (concat url (unless (string-match-p "[?&]$" url) (if (string-match-p "\\?" url) "&" "?")) ps)
    url))

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
  (let* ((p (string-search "=" string))
         (k (if p (substring string 0 p) string))
         (v (if p (substring string (1+ p)))))
    (cons k (when (and v (not (string-empty-p v)))
              (funcall (if url-decode #'url-unhex-string #'identity)
                       (string-trim v))))))

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

(defun pdd-http-code-text (http-status-code)
  "Return text description of the HTTP-STATUS-CODE."
  (caddr (assoc http-status-code url-http-codes)))

(defun pdd-funcall (fn args)
  "Call function FN with the first N arguments from ARGS, where N is FN's arity."
  (declare (indent 1))
  (let ((n (car (func-arity fn))))
    (apply fn (cl-loop for i from 1 to n for x in args collect x))))


;;; Core

(defvar pdd-base-url nil
  "Concat with url when the url is not started with http.
Use as dynamical binding usually." )

(defvar pdd-default-sync nil
  "The sync style when no :sync specified explicitly for function `pdd'.
It's value should be :sync or :async.  Default nil means not specified.")

(defvar pdd-default-timeout 60
  "Default timetout seconds for the request.")

(defvar pdd-default-error-handler nil
  "The default error handler which is a function same as callback of :fail.
When error occurrs and no :fail specified, this will perform as the handler.
Besides globally set, it also can be dynamically binding in let.")

(defvar pdd-retry-condition
  (lambda (err) (string-match-p "timeout\\|408" (format "%s" err)))
  "Function determine whether should retry the request.")

(defvar pdd-default-cookie-jar nil
  "Default cookie jar used when not specified in requests.

The value can be either:
- A cookie-jar instance, or
- A function that returns a cookie-jar.

When the value is a function, it may accept either:
- No arguments, or
- A single argument (the request instance).

This variable is used as a fallback when no cookie jar is explicitly
provided in individual requests.")

(defvar-local pdd-abort-flag nil
  "Non-nil means to ignore following request progress.")

(defvar pdd-request-transformers
  '(pdd-transform-req-done
    pdd-transform-req-filter
    pdd-transform-req-fail
    pdd-transform-req-headers
    pdd-transform-req-cookies
    pdd-transform-req-data
    pdd-transform-req-finally)
  "List of functions that transform the request object in sequence.

Each transformer is a function that takes the current request object as its
single argument.  Transformers are applied in the order they appear in this
list, with each transformer able to modify the request object before passing
it to the next.

This list contains built-in transformers that provide essential functionality.
While you may append additional transformers to customize behavior, you should
not remove or reorder the built-in transformers unless you fully understand the
consequences.")

(defvar pdd-response-transformers
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
stages.  While you may safely append additional transformers to extend
functionality, you should not remove or reorder the built-in transformers unless
you fully understand their interdependencies.")

;; Backend

(defclass pdd-backend ()
  ((insts :allocation :class :initform nil)
   (user-agent :initarg :user-agent :initform nil :type (or string null)))
  "Used to send http request."
  :abstract t)

(cl-defmethod make-instance ((class (subclass pdd-backend)) &rest slots)
  "Ensure CLASS with same SLOTS only has one instance."
  (if-let* ((key (sha1 (format "%s" slots)))
            (insts (oref-default class insts))
            (old (cdr-safe (assoc key insts))))
      old
    (let ((inst (cl-call-next-method)))
      (prog1 inst (oset-default class insts `((,key . ,inst) ,@insts))))))

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

;; Request

(defclass pdd-request ()
  ((url        :initarg :url      :type string)
   (method     :initarg :method   :type (or symbol string) :initform nil)
   (params     :initarg :params   :type (or string list)   :initform nil)
   (headers    :initarg :headers  :type list               :initform nil)
   (data       :initarg :data     :type (or function string list) :initform nil)
   (datas      :initform nil      :type (or string null))
   (binaryp    :initform nil      :type boolean)
   (resp       :initarg :resp     :type (or function null) :initform nil)
   (timeout    :initarg :timeout  :type (or number null)   :initform nil)
   (retry      :initarg :retry    :type (or number null)   :initform nil)
   (init       :initarg :init     :type (or function null) :initform nil)
   (filter     :initarg :filter   :type (or function null) :initform nil)
   (done       :initarg :done     :type (or function null) :initform nil)
   (fail       :initarg :fail     :type (or function null) :initform nil)
   (fine       :initarg :fine     :type (or function null) :initform nil)
   (sync       :initarg :sync)
   (buffer     :initarg :buffer :initform nil)
   (backend    :initarg :backend)
   (cookie-jar :initarg :cookie-jar :type (or pdd-cookie-jar function null) :initform nil))
  "Abstract base class for HTTP request configs.")

(cl-defmethod pdd-transform-req-done ((request pdd-request))
  "Construct the :done callback handler for REQUEST."
  (with-slots (done fail fine buffer backend) request
    (let ((args (cl-loop for arg in
                         (if (or (null done) (equal (func-arity done) '(0 . many)))
                             '(a1)
                           (help-function-arglist done))
                         until (memq arg '(&rest &optional &key))
                         collect arg)))
      (setf done
            `(lambda ,args
               (pdd-log 'done "enter")
               (unwind-protect
                   (condition-case err1
                       (with-current-buffer
                           (if (and (buffer-live-p ,buffer) (cl-plusp ,(length args)))
                               ,buffer
                             (current-buffer))
                         (prog1
                             (,(or done 'identity) ,@args)
                           (pdd-log 'done "finished.")))
                     (error (setq pdd-abort-flag 'done)
                            (pdd-log 'done "error. %s" err1)
                            (funcall ,fail err1)))
                 (ignore-errors (pdd-funcall ,fine (list ,request)))))))))

(cl-defmethod pdd-transform-req-filter ((request pdd-request))
  "Construct the :filter callback handler for REQUEST."
  (with-slots (filter fail) request
    (when filter
      (setf filter
            (let ((filter1 filter))
              (lambda ()
                (if pdd-abort-flag
                    (pdd-log 'filter "skip (aborted).")
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
                    (error
                     (pdd-log 'filter "fail: %s" err1)
                     (setq pdd-abort-flag 'filter)
                     (funcall fail err1))))))))))

(cl-defmethod pdd-transform-req-fail ((request pdd-request))
  "Construct the :fail callback handler for REQUEST."
  (with-slots (retry fail fine backend) request
    (setf fail
          (let ((fail1 (or fail pdd-default-error-handler)))
            (lambda (err)
              (pdd-log 'fail "enter: %s | %s" err (or fail1 'None))
              ;; retry
              (if (and (cl-plusp retry) (funcall pdd-retry-condition err))
                  (progn
                    (if pdd-debug
                        (pdd-log 'fail "retrying (remains %d times)..." retry)
                      (let ((inhibit-message t))
                        (message "(%d) retring for %s..." retry (cadr err))))
                    (cl-decf retry)
                    (funcall #'pdd backend request))
                ;; really fail now
                (pdd-log 'fail "really, it's fail...")
                (unwind-protect
                    (cl-flet ((show-error (obj)
                                (when (eq (car err) 'error) ; avoid 'peculiar error'
                                  (setf (car err) 'user-error))
                                (message
                                 "%s%s"
                                 (if pdd-abort-flag (format "[%s] " pdd-abort-flag) "")
                                 (if (get (car obj) 'error-conditions)
                                     (error-message-string obj)
                                   (mapconcat (lambda (e) (format "%s" e)) obj ", ")))))
                      (condition-case err1
                          (if fail1 ; ensure no error in this phase
                              (progn
                                (pdd-log 'fail "display error with :fail.")
                                (pdd-funcall fail1 (list (cadr err) (car-safe (cddr err)) err request)))
                            (pdd-log 'fail "no :fail, just show it.")
                            (show-error err))
                        (error
                         (pdd-log 'fail "oooop, error occurs when display error.")
                         (show-error err1))))
                  ;; finally
                  (ignore-errors (pdd-funcall fine (list request))))))))))

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
                           (alist-get item pdd-header-rewrite-rules)))
           collect (funcall stringfy v)
           else if (setq v (and (consp item)
                                (symbolp (car item))
                                (or (null (cdr item)) (car-safe (cdr item)))
                                (alist-get (car item) pdd-header-rewrite-rules)))
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
        (let* ((url-obj (url-generic-parse-url url))
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
              (let ((ct (alist-get "Content-Type" headers nil nil #'string-equal-ignore-case)))
                (cond ((string-match-p "/json" (or ct ""))
                       (setf binaryp t)
                       (encode-coding-string (json-encode data) 'utf-8))
                      ((cl-some (lambda (x) (consp (cdr x))) data)
                       (setf binaryp t)
                       (setf (alist-get "Content-Type" headers nil nil #'string-equal-ignore-case)
                             (concat "multipart/form-data; boundary=" pdd-multipart-boundary))
                       (pdd-format-formdata data))
                      (t
                       (unless ct (setf (alist-get "Content-Type" headers nil nil #'string-equal-ignore-case)
                                        "application/x-www-form-urlencoded"))
                       (pdd-format-params data)))))))))

(cl-defmethod pdd-transform-req-finally ((request pdd-request))
  "Other change should be made for REQUEST."
  (with-slots (headers datas binaryp backend) request
    (unless (assoc "User-Agent" headers #'string-equal-ignore-case)
      (push `("User-Agent" . ,(or (oref backend user-agent) pdd-user-agent)) headers))
    (when (and (not binaryp) datas)
      (setf binaryp (not (multibyte-string-p datas))))))

(cl-defmethod initialize-instance :after ((request pdd-request) &rest _)
  "Initialize the configs for REQUEST."
  (pdd-log 'req "req:init...")
  (with-slots (url method params data timeout retry sync done buffer) request
    (when (and pdd-base-url (string-prefix-p "/" url))
      (setf url (concat pdd-base-url url)))
    (when params
      (setf url (pdd-gen-url-with-params url params)))
    (unless (slot-boundp request 'sync)
      (setf sync (if pdd-default-sync
                     (if (eq pdd-default-sync :sync) t nil)
                   (if done nil :sync))))
    (unless method (setf method (if data 'post 'get)))
    (unless timeout (setf timeout pdd-default-timeout))
    (unless retry (setf retry pdd-max-retry))
    (unless buffer (setf buffer (current-buffer)))
    ;; run all of the installed transformers with request
    (cl-loop for transformer in pdd-request-transformers
             do (pdd-log 'req (help-fns-function-name transformer))
             do (funcall transformer request))))

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
  (setq pdd-resp-headers (pdd-extract-http-headers)))

(cl-defmethod pdd-transform-resp-cookies (request)
  "Save cookies from response to cookie jar for REQUEST."
  (with-slots (cookie-jar url) request
    (when (and cookie-jar pdd-resp-headers)
      (cl-loop with domain = (or (url-host (url-generic-parse-url url)) "")
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
  (with-slots (resp url) request
    (setq pdd-resp-body
          (buffer-substring pdd-resp-mark (point-max)))
    (cond
     ((functionp resp)
      (setq pdd-resp-body
            (pdd-funcall resp (list pdd-resp-body pdd-resp-headers))))
     ((string-match-p "/json" (alist-get 'content-type pdd-resp-headers))
      (setq pdd-resp-body
            (json-read-from-string pdd-resp-body))))))

(cl-defmethod pdd-transform-response (request)
  "Run all response transformers for REQUEST to get the results."
  (if pdd-abort-flag
      (pdd-log 'resp "skip (aborted).")
    (with-slots (backend) request
      (cl-loop for transformer in pdd-response-transformers
               do (pdd-log 'resp (help-fns-function-name transformer))
               do (funcall transformer request))
      (list pdd-resp-body pdd-resp-headers
            pdd-resp-status pdd-resp-version request))))

;; Entrance

(cl-defgeneric pdd-make-request (backend &rest _arg)
  "Instance request object for BACKEND."
  (:method ((backend pdd-backend) &rest args)
           (apply #'pdd-request `(:backend ,backend :url ,@args))))

(cl-defgeneric pdd (backend url &rest _args &key
                            method
                            params
                            headers
                            data
                            resp
                            init
                            filter
                            done
                            fail
                            fine
                            sync
                            timeout
                            retry
                            &allow-other-keys)
  "Send HTTP request using the specified BACKEND.

This is a generic function with implementations provided by backend classes.

Parameters:
  BACKEND  - HTTP backend instance
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
  :RESP    - Response transformer function for raw response data, signature:
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

Returns:
  Response data in sync mode, process object in async mode.

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
  (:method :around ((backend pdd-backend) &rest args)
           (let ((request (if (cl-typep (car args) 'pdd-request)
                              (car args)
                            (apply #'pdd-make-request backend args))))
             (pdd-log 'req "pdd:around...")
             ;; User's :init callback is the final chance to change request
             (with-slots (init) request (if init (pdd-funcall init (list request))))
             ;; derived to specified backend to deal with the real request
             (funcall #'cl-call-next-method backend :request request)))
  (declare (indent 1)))


;;; Implement for url.el

(defclass pdd-url-backend (pdd-backend)
  ((proxy-services
    :initarg :proxies
    :initform nil
    :type (or list null)
    :documentation "Proxy services passed to `url.el', see `url-proxy-services' for details."))
  :documentation "Http Backend implemented using `url.el'.")

(defvar url-http-content-type)
(defvar url-http-end-of-headers)
(defvar url-http-transfer-encoding)
(defvar url-http-response-status)
(defvar url-http-response-version)

(defvar pdd-url-extra-filter nil)

(cl-defmethod pdd-transform-error ((_ pdd-url-backend) status)
  "Extract error object from callback STATUS."
  (cond ((null status)
         (setq pdd-abort-flag 'conn)
         `(http "Maybe something wrong with network" 400))
        ((or (null url-http-end-of-headers) (= 1 (point-max)))
         (setq pdd-abort-flag 'conn)
         `(http "Response unusual empty content" 417))
        ((plist-get status :error)
         (setq pdd-abort-flag 'resp)
         (let* ((err (plist-get status :error))
                (code (caddr err)))
           `(,(car err) ,(pdd-http-code-text code) ,code)))))

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
  (with-slots (url method headers datas binaryp resp filter done fail timeout sync) request
    (let* ((tag (eieio-object-class backend))
           (url-request-data datas)
           (url-request-extra-headers headers)
           (url-request-method (string-to-unibyte (upcase (format "%s" method))))
           (url-mime-encoding-string "identity")
           (url-proxy-services (or (oref backend proxy-services) url-proxy-services))
           buffer-data data-buffer timer
           (callback (lambda (status)
                       (pdd-log tag "callback.")
                       (ignore-errors (cancel-timer timer))
                       (setq data-buffer (current-buffer))
                       (remove-hook 'after-change-functions #'pdd-url-http-extra-filter t)
                       (if pdd-abort-flag
                           (pdd-log tag "skip done (aborted).")
                         (unwind-protect
                             (if-let* ((err (pdd-transform-error backend status)))
                                 (progn (pdd-log tag "before fail")
                                        (funcall fail err))
                               (pdd-log tag "before done")
                               (setq buffer-data (pdd-funcall done (pdd-transform-response request))))
                           (unless sync (kill-buffer data-buffer))))))
           (proc-buffer (url-retrieve url callback nil t t))
           (process (get-buffer-process proc-buffer)))
      ;; log
      (pdd-log tag
        "%s %s"             url-request-method url
        "HEADER: %S"        url-request-extra-headers
        "DATA: %s"          url-request-data
        "BINARY: %s"        binaryp
        "Proxy: %s"         url-proxy-services
        "User Agent: %s"    url-user-agent
        "MIME Encoding: %s" url-mime-encoding-string)
      ;; Weird, but you have to bind `url-user-agent' like this to make it work
      (setf (buffer-local-value 'url-user-agent proc-buffer)
            (unless (assoc "User-Agent" headers #'string-equal-ignore-case)
              (oref backend user-agent) pdd-user-agent))
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
              (while (and (process-live-p process)
                          (not (buffer-local-value 'pdd-abort-flag proc-buffer))
                          (not data-buffer))
                (accept-process-output nil 0.05)))
            buffer-data)
        process))))


;;; Implement for plz.el

(defclass pdd-plz-backend (pdd-backend)
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

(defvar pdd-plz-initialize-error-message
  "\n\nTry to install curl and specify the program like this to solve the problem:\n
  (setq plz-curl-program \"c:/msys64/usr/bin/curl.exe\")\n
Or switch http backend to `pdd-url-backend' instead:\n
  (setq pdd-default-backend (pdd-url-backend))")

(cl-defmethod pdd :before ((_ pdd-plz-backend) &rest _)
  "Check if `plz.el' is available."
  (unless (and (require 'plz nil t) (executable-find plz-curl-program))
    (error "You should have `plz.el' and `curl' installed before using `pdd-plz-backend'")))

(cl-defmethod pdd-transform-error ((_ pdd-plz-backend) error)
  "Hacky, but try to unify the ERROR data format with url.el."
  (when (and (consp error) (memq (car error) '(plz-http-error plz-curl-error)))
    (setq error (caddr error)))
  (if (not (plz-error-p error)) error
    (if-let* ((msg (plz-error-message error)))
        (list 'plz-error msg)
      (if-let* ((curl (plz-error-curl-error error)))
          (list 'plz-error
                (concat (format "%s" (or (cdr curl) (car curl)))
                        (pcase (car curl)
                          (2 (when (memq system-type '(cygwin windows-nt ms-dos))
                               pdd-plz-initialize-error-message)))))
        (if-let* ((res (plz-error-response error))
                  (code (plz-response-status res)))
            (list 'error (pdd-http-code-text code) code)
          error)))))

(cl-defmethod pdd ((backend pdd-plz-backend) &key request)
  "Send REQUEST with plz as BACKEND."
  (with-slots (url method headers datas binaryp resp filter done fail timeout sync) request
    (let* ((tag (eieio-object-class backend))
           (abort-flag) ; used to catch abort action from :filter
           (plz-curl-default-args
            (if (slot-boundp backend 'extra-args)
                (append (oref backend extra-args) plz-curl-default-args)
              plz-curl-default-args))
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
                        (unwind-protect
                            (funcall filter)
                          (setq abort-flag pdd-abort-flag)))))))))
           (results (lambda ()
                      (pdd-log tag "before resp")
                      (pdd-transform-response request))))
      ;; log
      (pdd-log tag
        "%s"          url
        "HEADER: %s"  headers
        "DATA: %s"    datas
        "BINARY: %s"  binaryp
        "EXTRA: %s"   plz-curl-default-args)
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
             (funcall fail (pdd-transform-error backend err))))
        ;; async
        (plz method url
          :headers headers
          :body datas
          :body-type (if binaryp 'binary 'text)
          :decode nil
          :as results
          :filter filter-fn
          :then (lambda (res)
                  (if pdd-abort-flag
                      (pdd-log tag "skip done (aborted).")
                    (pdd-log tag "before done")
                    (pdd-funcall done res)))
          :else (lambda (err)
                  (pdd-log tag "before fail")
                  (funcall fail (pdd-transform-error backend err)))
          :timeout timeout)))))



(defvar pdd-default-backend
  (if (and (require 'plz nil t) (executable-find plz-curl-program))
      (pdd-plz-backend)
    (pdd-url-backend))
  "Default backend used by `pdd' for HTTP requests.

The value can be either:
- A instance of function `pdd-backend', or
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
