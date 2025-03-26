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
;; A versatile HTTP client library that provides a unified interface making
;; http requests across multiple backend implementations easily. It is designed
;; for simplicity, flexibility and cross-platform compatibility.
;;
;;  - Choose between built-in `url.el' or high-performance `curl' backends. It
;;    gracefully falls back to `url.el' when `curl' is unavailable without
;;    requiring code changes.
;;  - Rich feature set including multipart uploads, streaming support,
;;    automatic retry strategies, and smart data conversion. Enhances `url.el'
;;    to support all these capabilities and works well enough.
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

(defun pdd-log (tag fmt &rest args)
  "Output log to *Messages* buffer.
TAG usually is the name of current http backend.
FMT and ARGS are arguments same as function `message'."
  (apply #'message (format "[%s] %s" (or tag "pdd") fmt) args))

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

Handles both regular fields and file uploads with proper boundary formatting."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (cl-loop for (key . value) in alist for i from 1
             for filep = nil for contentype = nil
             do (setq key (format "%s" key))
             do (if (consp value) ; ((afile "~/aaa.jpg" "image/jpeg"))
                    (setq contentype (or (cadr value) "application/octet-stream")
                          value (format "%s" (car value)) filep t)
                  (setq value (format "%s" value)))
             for newline = "\r\n"
             do (insert "--" pdd-multipart-boundary newline)
             ;; It's not efficient to do this in emacs, but it does work
             if filep do (let ((fn (url-encode-url (url-file-nondirectory value))))
                           (insert "Content-Disposition: form-data; name=\"" key "\" filename=\"" fn "\"" newline)
                           (insert "Content-Type: " contentype newline newline)
                           (insert-file-contents-literally value)
                           (goto-char (point-max)))
             else do (insert "Content-Disposition: form-data; name=\"" key "\"" newline newline value)
             if (< i (length alist)) do (insert newline)
             else do (insert newline "--" pdd-multipart-boundary "--"))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun pdd-transform-result (data headers &optional transformer)
  "Transform response DATA according to HEADERS and TRANSFORMER."
  (if pdd-debug (pdd-log nil "transform response..."))
  (let* ((content-type (alist-get 'content-type headers))
         (binaryp (pdd-binary-type-p content-type)))
    (setq data (if binaryp
                   (encode-coding-string data 'binary)
                 (decode-coding-string data (pdd-detect-charset content-type))))
    (if (functionp transformer)
        (pdd-funcall transformer (list data headers))
      (cond
       ((string-match-p "application/json" content-type)
        (json-read-from-string data))
       (t data)))))

(defun pdd-extract-http-headers ()
  "Extract http headers from the current response buffer."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (forward-line 1)
      (cl-loop for el in (mail-header-extract)
               collect (cons (car el) (string-trim (cdr el)))))))

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

(defvar-local pdd-abort-flag nil
  "Non-nil means to ignore following request progress.")

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

(defclass pdd-request ()
  ((url      :initarg :url      :type string)
   (method   :initarg :method   :type (or symbol string) :initform nil)
   (params   :initarg :params   :type (or string list)   :initform nil)
   (headers  :initarg :headers  :type list               :initform nil)
   (data     :initarg :data     :type (or function string list) :initform nil)
   (resp     :initarg :resp     :type (or function null) :initform nil)
   (timeout  :initarg :timeout  :type (or number null)   :initform nil)
   (retry    :initarg :retry    :type (or number null)   :initform nil)
   (filter   :initarg :filter   :type (or function null) :initform nil)
   (done     :initarg :done     :type (or function null) :initform nil)
   (fail     :initarg :fail     :type (or function null) :initform nil)
   (fine     :initarg :fine     :type (or function null) :initform nil)
   (sync     :initarg :sync)
   (binaryp  :initform nil :type boolean)
   (buffer   :initarg :buffer :initform nil)
   (backend   :initarg :backend))
  "Abstract base class for HTTP request configs.")

(cl-defmethod pdd-build ((request pdd-request) (_ (eql 'fail)))
  "Construct the :fail callback handler for REQUEST."
  (with-slots (retry fail fine backend) request
    (let ((fail fail) (tag (eieio-object-class backend)))
      (lambda (err)
        (if pdd-debug (pdd-log tag "error object: %S" err))
        ;; retry
        (if (and (cl-plusp retry) (funcall pdd-retry-condition err))
            (progn
              (let ((inhibit-message t))
                (message "Retring for %s %d..." (cadr err) retry))
              (if pdd-debug (pdd-log tag "Retrying for %s (remains %d times)..." err retry))
              (cl-decf retry)
              (funcall #'pdd backend request))
          ;; really fail now
          (if pdd-debug (pdd-log tag "Handle fail..."))
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
                    (if fail ; ensure no error in this phase
                        (pdd-funcall fail (cadr err) (car-safe (cddr err)) err request)
                      (show-error err))
                  (error (show-error err1))))
            ;; finally
            (ignore-errors (pdd-funcall fine request))))))))

(cl-defmethod pdd-build ((request pdd-request) (_ (eql 'done)))
  "Construct the :done callback handler for REQUEST."
  (with-slots (done fail fine buffer backend) request
    (let ((args (cl-loop for arg in
                         (if (or (null done) (equal (func-arity done) '(0 . many)))
                             '(a1)
                           (help-function-arglist done))
                         until (memq arg '(&rest &optional &key))
                         collect arg)))
      (if (> (length args) 5)
          (user-error "Function :done has invalid arguments")
        `(lambda ,args
           (if pdd-debug (pdd-log ,(eieio-object-class backend) "Done!"))
           (unwind-protect
               (condition-case err1
                   (with-current-buffer
                       (if (and (buffer-live-p ,buffer) (cl-plusp ,(length args)))
                           ,buffer
                         (current-buffer))
                     (,(or done 'identity) ,@args))
                 (error (setq pdd-abort-flag 'done)
                        (if pdd-debug (pdd-log 'pdd "error occurs in done phase.."))
                        (funcall ,fail err1)))
             (ignore-errors (pdd-funcall ,fine ,request))))))))

(cl-defmethod pdd-build ((request pdd-request) (_ (eql 'filter)))
  "Construct the :filter callback handler for REQUEST."
  (with-slots (filter fail backend) request
    (let ((filter filter) (tag (eieio-object-class backend)))
      (lambda ()
        ;; abort action and error case
        (condition-case err1
            (unless pdd-abort-flag
              (if (zerop (length (help-function-arglist filter)))
                  ;; with no argument
                  (funcall filter)
                ;; arguments: (&optional headers process request)
                (pdd-funcall filter
                  (pdd-extract-http-headers)
                  (get-buffer-process (current-buffer))
                  request)))
          (error
           (if pdd-debug (pdd-log tag "Error in filter: %s" err1))
           (setq pdd-abort-flag 'filter)
           (funcall fail err1)))))))

(cl-defmethod pdd-transform-request ((request pdd-request))
  "Transform data, headers and others in REQUEST."
  (if pdd-debug (pdd-log nil "transform request..."))
  (with-slots (data headers binaryp) request
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
           collect (funcall stringfy item)))
    (setf data
          (when data
            (if (functionp data) ; Wrap data in a function can avoid be converted
                (format "%s" (pdd-funcall data headers))
              (if (atom data) ; Never modify the Content-Type when data is atom/string
                  (format "%s" data)
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
                         (pdd-format-params data))))))))
    (when (and (not binaryp) (stringp data))
      (setf binaryp (not (multibyte-string-p data))))))

(cl-defmethod initialize-instance :after ((request pdd-request) &rest _)
  "Initialize the configs for REQUEST."
  (with-slots (url method params headers data binaryp timeout retry sync done fail filter buffer backend) request
    (pdd-transform-request request) ; transform first
    (when (and pdd-base-url (string-prefix-p "/" url))
      (setf url (concat pdd-base-url url)))
    (when params
      (setf url (pdd-gen-url-with-params url params)))
    (unless (slot-boundp request 'sync)
      (setf sync (if pdd-default-sync
                     (if (eq pdd-default-sync :sync) t nil)
                   (if done nil :sync))))
    ;; user-agent should be always settled
    (unless (assoc "User-Agent" headers #'string-equal-ignore-case)
      (push `("User-Agent" . ,(or (oref backend user-agent) pdd-user-agent)) headers))
    (unless method (setf method (if data 'post 'get)))
    (unless timeout (setf timeout pdd-default-timeout))
    (unless retry (setf retry pdd-max-retry))
    (unless buffer (setf buffer (current-buffer)))
    ;; decorate the callbacks
    (unless fail (setf fail pdd-default-error-handler))
    (setf fail (pdd-build request 'fail))
    (setf done (pdd-build request 'done))
    (when filter (setf filter (pdd-build request 'filter)))))

(cl-defgeneric pdd (backend url &rest _args &key
                            method
                            params
                            headers
                            data
                            resp
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
                            (apply #'pdd-request `(:backend ,backend :url ,@args)))))
             (if pdd-debug (pdd-log 'backend "around pdd..."))
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

(cl-defmethod pdd-transform-response ((_ pdd-url-backend) request)
  "Extract results from proc buffer for REQUEST."
  (with-slots (done resp) request
    ;; don't wasting time on decode/extract when :done has no args
    (unless (zerop (car (func-arity done)))
      (let* ((headers (pdd-extract-http-headers))
             (raw (progn (goto-char url-http-end-of-headers)
                         (buffer-substring-no-properties (min (+ (point) 1) (point-max)) (point-max))))
             (body (pdd-transform-result raw headers resp)))
        ;; pass all these data to done. pity elisp has no values mechanism
        (list body headers url-http-response-status url-http-response-version request)))))

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
  (with-slots (url method headers data binaryp resp filter done fail timeout sync) request
    (let* ((tag (eieio-object-class backend))
           (url-request-data data)
           (url-request-extra-headers headers)
           (url-request-method (string-to-unibyte (upcase (format "%s" method))))
           (url-mime-encoding-string "identity")
           (url-proxy-services (or (oref backend proxy-services) url-proxy-services))
           buffer-data data-buffer timer
           (callback (lambda (status)
                       (ignore-errors (cancel-timer timer))
                       (setq data-buffer (current-buffer))
                       (remove-hook 'after-change-functions #'pdd-url-http-extra-filter t)
                       (unless pdd-abort-flag
                         (unwind-protect
                             (if-let* ((err (pdd-transform-error backend status)))
                                 (funcall fail err) ; :fail has been decorated, it's non-nil and has a required argument
                               (setq buffer-data (apply #'pdd-funcall done (pdd-transform-response backend request))))
                           (unless sync (kill-buffer data-buffer))))))
           (proc-buffer (url-retrieve url callback nil t))
           (process (get-buffer-process proc-buffer)))
      ;; log
      (when pdd-debug
        (pdd-log tag "%s %s" url-request-method url)
        (pdd-log tag "HEADER: %S" url-request-extra-headers)
        (pdd-log tag "DATA: %s" url-request-data)
        (pdd-log tag "BINARYp: %s" binaryp)
        (pdd-log tag "Proxy: %s" url-proxy-services)
        (pdd-log tag "User Agent: %s" url-user-agent)
        (pdd-log tag "MIME Encoding: %s" url-mime-encoding-string))
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
                 (unless data-buffer
                   (ignore-errors
                     (stop-process process))
                   (ignore-errors
                     (with-current-buffer proc-buffer
                       (erase-buffer)
                       (setq-local url-http-end-of-headers 30)
                       (insert "HTTP/1.1 408 Operation timeout")))
                   (ignore-errors
                     (delete-process process))))))
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

(cl-defmethod pdd-transform-response ((_ pdd-plz-backend) request)
  "Extract results from proc buffer for REQUEST."
  (with-slots (done resp) request
    (unless pdd-abort-flag
      (widen)
      (goto-char (point-min))
      (save-excursion ; Clean the ^M, make it same as in url.el
        (while (search-forward "\r" nil :noerror) (replace-match "")))
      (unless (zerop (car (func-arity done)))
        (let ((url-http-end-of-headers t)
              (headers (pdd-extract-http-headers)))
          (url-http-parse-response)
          (unless (re-search-forward plz-http-end-of-headers-regexp nil t)
            (signal 'plz-http-error '("Unable to find end of headers")))
          (list (pdd-transform-result
                 (buffer-substring-no-properties (point) (point-max))
                 headers resp)
                headers url-http-response-status url-http-response-version request))))))

(cl-defmethod pdd-transform-error ((_ pdd-plz-backend) err)
  "Hacky, but try to unify the ERR data format with url.el."
  (when (and (consp err) (memq (car err) '(plz-http-error plz-curl-error)))
    (setq err (caddr err)))
  (if (not (plz-error-p err)) err
    (if-let* ((msg (plz-error-message err)))
        (list 'plz-error msg)
      (if-let* ((curl (plz-error-curl-error err)))
          (list 'plz-error
                (concat (format "%s" (or (cdr curl) (car curl)))
                        (pcase (car curl)
                          (2 (when (memq system-type '(cygwin windows-nt ms-dos))
                               pdd-plz-initialize-error-message)))))
        (if-let* ((res (plz-error-response err))
                  (code (plz-response-status res)))
            (list 'error (pdd-http-code-text code) code)
          err)))))

(cl-defmethod pdd ((backend pdd-plz-backend) &key request)
  "Send REQUEST with plz as BACKEND."
  (with-slots (url method headers data binaryp resp filter done fail timeout sync) request
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
           (results (lambda () (pdd-transform-response backend request))))
      ;; data and headers
      (unless (alist-get "User-Agent" headers nil nil #'string-equal-ignore-case)
        (push `("User-Agent" . ,(or (oref backend user-agent) pdd-user-agent)) headers))
      ;; log
      (when pdd-debug
        (pdd-log tag "%s" url)
        (pdd-log tag "HEADER: %s" headers)
        (pdd-log tag "DATA: %s" data)
        (pdd-log tag "BINARYp: %s" binaryp)
        (pdd-log tag "EXTRA: %s" plz-curl-default-args))
      ;; sync
      (if sync
          (condition-case err
              (let ((res (plz method url
                           :headers headers
                           :body data
                           :body-type (if binaryp 'binary 'text)
                           :decode nil
                           :as results
                           :filter filter-fn
                           :then 'sync
                           :timeout timeout)))
                (unless abort-flag (apply #'pdd-funcall done res)))
            (error (funcall fail (pdd-transform-error backend err))))
        ;; async
        (plz method url
          :headers headers
          :body data
          :body-type (if binaryp 'binary 'text)
          :decode nil
          :as results
          :filter filter-fn
          :then (lambda (res) (unless pdd-abort-flag (apply #'pdd-funcall done res)))
          :else (lambda (err) (funcall fail (pdd-transform-error backend err)))
          :timeout timeout)))))



(defvar pdd-default-backend
  (if (and (require 'plz nil t) (executable-find plz-curl-program))
      (pdd-plz-backend)
    (pdd-url-backend))
  "Backend used by `pdd' by default.
This should be instance of symbol `pdd-backend', or a function with current
url or url+method as arguments that return an instance.  If is a function,
the backend be used will be determined dynamically when the `pdd' be called.")

(defun pdd-ensure-default-backend (args)
  "Pursue the value of variable `pdd-default-backend' if it is a function.
ARGS should be the arguments of function `pdd'."
  (if (functionp pdd-default-backend)
      (pcase (car (func-arity pdd-default-backend))
        (1 (funcall pdd-default-backend (car args)))
        (2 (funcall pdd-default-backend (car args)
                    (intern-soft
                     (or (plist-get (cdr args) :method)
                         (if (plist-get (cdr args) :data) 'post 'get)))))
        (_ (user-error "If `pdd-default-backend' is a function, it can only have
one argument (url) or two arguments (url method)")))
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
  "Send a request with `pdd-default-backend'.
In this case, the first argument in ARGS should be url instead of backend.
See the generic method for other ARGS and details."
  (let* ((args (apply #'pdd-complete-absent-keywords args))
         (backend (pdd-ensure-default-backend args)))
    (unless (and backend (eieio-object-p backend) (object-of-class-p backend 'pdd-backend))
      (user-error "Make sure `pdd-default-backend' is available.  eg:\n
(setq pdd-default-backend (pdd-url-backend))\n\n\n"))
    (apply #'pdd backend args)))

(provide 'pdd)

;;; pdd.el ends here
