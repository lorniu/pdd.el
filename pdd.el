;;; pdd.el --- HTTP Library Adapter, support url, plz and more -*- lexical-binding: t -*-

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
;; HTTP Library Adapter, support url.el and plz.el, and can be extended.
;;
;;  - API is simple and uniform
;;  - Support both sync/async request
;;  - Support streaming request
;;  - Support retry for timeout
;;  - Support config proxies for client
;;  - Support file upload/download
;;
;; See README.md of https://github.com/lorniu/pdd.el for more details.

;;; Code:

(require 'cl-lib)
(require 'url)
(require 'eieio)
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

(defcustom pdd-multipart-boundary "pdd-boundary-=-=+O0o0O69Oo"
  "A string used as multipart boundary."
  :type 'string)

(defun pdd-log (tag fmt &rest args)
  "Output log to *Messages* buffer.
TAG usually is the name of current http client.
FMT and ARGS are arguments same as function `message'."
  (apply #'message (format "[%s] %s" (or tag "pdd") fmt) args))

(defun pdd-binary-type-p (content-type)
  "Check if current CONTENT-TYPE is binary."
  (when content-type
    (cl-destructuring-bind (mime sub) (string-split content-type "/" nil "[ \n\r\t]")
      (not (or (equal mime "text")
               (and (equal mime "application")
                    (string-match-p "json\\|xml\\|php" sub)))))))

(defun pdd-format-params (alist)
  "Format ALIST to k=v style query string."
  (mapconcat (lambda (arg)
               (format "%s=%s"
                       (url-hexify-string (format "%s" (car arg)))
                       (url-hexify-string (format "%s" (or (cdr arg) 1)))))
             (delq nil alist) "&"))

(defun pdd-gen-url-with-params (url params)
  "Concat PARAMS to URL, and return it."
  (if-let* ((ps (if (consp params) (pdd-format-params params) params)))
      (concat url (unless (string-match-p "[?&]$" url) (if (string-match-p "\\?" url) "&" "?")) ps)
    url))

(defun pdd-format-formdata (alist)
  "Generate multipart/formdata string from ALIST."
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
             if filep do (let ((fn (url-encode-url (url-file-nondirectory value))))
                           (insert "Content-Disposition: form-data; name=\"" key "\" filename=\"" fn "\"" newline)
                           (insert "Content-Type: " contentype newline newline)
                           (insert-file-contents-literally value)
                           (goto-char (point-max)))
             else do (insert "Content-Disposition: form-data; name=\"" key "\"" newline newline value)
             if (< i (length alist)) do (insert newline)
             else do (insert newline "--" pdd-multipart-boundary "--"))
    (buffer-substring-no-properties (point-min) (point-max))))

(defvar pdd-header-rewrite-rules
  '((ua-emacs    . ("User-Agent"    . "Emacs Agent"))
    (keep-alive  . ("Connection"    . "Keep-Alive"))
    (json        . ("Content-Type"  . "application/json"))
    (json-u8     . ("Content-Type"  . "application/json; charset=utf-8"))
    (www-url     . ("Content-Type"  . "application/x-www-form-urlencoded"))
    (www-url-u8  . ("Content-Type"  . "application/x-www-form-urlencoded; charset=utf-8"))
    (acc-github  . ("Accept"        . "application/vnd.github+json"))
    (bear        . ("Authorization" . "Bearer %s"))
    (auth        . ("Authorization" . "%s %s")))
  "Some abbrevs can be used in alist of headers for short.
They are be replaced when transforming request.")

(defun pdd-transform-request (data headers)
  "Transform DATA and HEADERS for request."
  (if pdd-debug (pdd-log nil "transform response..."))
  (let (binaryp)
    (setq headers
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
    (setq data
          (when data
            (if (atom data) (format "%s" data)
              (let ((ct (alist-get "Content-Type" headers nil nil #'string-equal-ignore-case)))
                (cond ((string-match-p "/json" (or ct ""))
                       (setq binaryp t)
                       (encode-coding-string (json-encode data) 'utf-8))
                      ((cl-some (lambda (x) (consp (cdr x))) data)
                       (setq binaryp t)
                       (setf (alist-get "Content-Type" headers nil nil #'string-equal-ignore-case)
                             (concat "multipart/form-data; boundary=" pdd-multipart-boundary))
                       (pdd-format-formdata data))
                      (t (pdd-format-params data)))))))
    (list data headers binaryp)))

(defun pdd-transform-response (data meta)
  "Transform responsed DATA according META.
META maybe a function or the response headers."
  (if pdd-debug (pdd-log nil "transform response..."))
  (if (functionp meta)
      (funcall meta data)
    (let ((ct (alist-get 'content-type meta)))
      (cond ((string-match-p "application/json" ct)
             (json-read-from-string (decode-coding-string data 'utf-8)))
            (t data)))))

(defun pdd-extract-http-headers ()
  "Extract http headers from the current responsed buffer."
  (save-excursion
    (goto-char (point-min))
    (forward-line 1)
    (cl-loop for el in (mail-header-extract)
             collect (cons (car el) (string-trim (cdr el))))))

(defun pdd-funcall (fn args)
  "Funcall FN and pass some of ARGS to it according its arity."
  (declare (indent 1))
  (let ((n (car (func-arity fn))))
    (apply fn (cl-loop for i from 1 to n for x in args collect x))))


;;; Core

(defvar pdd-default-sync nil
  "The sync style when no :sync specified explicitly for function `pdd'.
It's value should be :sync or :async.")

(defvar-local pdd-abort-flag nil
  "Non-nil means to ignore following request progress.")

(defvar pdd-default-error-handler nil
  "The default error handler which is a function with current error as argument.
When error occurrs and no :fail specified, this will perform as the handler.
Besides globally set, it also can be dynamically binding in let.")

(defclass pdd-client ()
  ((insts :allocation :class :initform nil)
   (user-agent :initarg :user-agent :initform nil :type (or string null)))
  "Used to send http request."
  :abstract t)

(cl-defmethod make-instance ((class (subclass pdd-client)) &rest slots)
  "Ensure CLASS with same SLOTS only has one instance."
  (if-let* ((key (sha1 (format "%s" slots)))
            (insts (oref-default class insts))
            (old (cdr-safe (assoc key insts))))
      old
    (let ((inst (cl-call-next-method)))
      (prog1 inst (oset-default class insts `((,key . ,inst) ,@insts))))))

(cl-defgeneric pdd (pdd-client url &rest _args &key
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
  "Send HTTP request using the given PDD-CLIENT.

Keyword arguments:
  - URL: The URL to send the request to.
  - PARAMS: The data to include in the url.  It's a string or alist.
  - METHOD: Request method, symbol like \\='post.  If nil guess by data.
  - HEADERS: Additional headers to include in the request.  Alist.
  - DATA: The data to include in the request.  If this is a string, it will be
          sent directly as request body.  If this is a list and every element
          is (key . value) then this will be joined to a string like a=1&b=2 and
          then be sent.  If this is a list and some element is (key filename)
          format, then the list will be normalized as multipart formdata string
          and be sent.
  - RESP: Whether or how to auto encode the response content.
          Currently this should a function with responsed string as argument.
          For example, make this with value #\\='identity should make
          the raw responsed string is passed to DONE without any parsed..
  - FILTER: A function to be called every time when some data returned.
  - DONE: A function to be called when the request succeeds.
  - FAIL: A function to be called when the request fails.
  - FINE: A function to be called at last, no matter done or fail.
  - RETRY: How many times it can retry for timeout.  Number.
  - TIMEOUT: Set connect timeout for request.  Number.
  - SYNC: Non-nil means request synchronized.  Boolean.

If request async, return the process behind the request."
  (:method :around ((client pdd-client) url &rest args &key method params _headers data _resp
                    filter done fail fine (sync t sync-supplied) _timeout retry &aux origin-url)
           ;; normalize and validate
           (unless sync-supplied
             (setq sync (if pdd-default-sync
                            (if (eq pdd-default-sync :sync) t nil)
                          (if done nil t))))
           (setq args `(:sync ,sync ,@args))
           (if (null method) (setq args `(:method ,(if data 'post 'get) ,@args)))
           (setq origin-url url url (pdd-gen-url-with-params origin-url params))
           (let* ((tag (eieio-object-class client))
                  (origin-buffer (current-buffer))
                  (fail (or fail pdd-default-error-handler))
                  (failfn
                   (lambda (status)
                     ;; retry for timeout
                     (unless retry (setq retry pdd-max-retry))
                     (if (and (cl-plusp retry) (string-match-p "timeout\\|504" (format "%s" status)))
                         (progn
                           (let ((inhibit-message t))
                             (message "Timeout, retrying (%d)..." retry))
                           (if pdd-debug (pdd-log tag "Request timeout, retrying (remains %d times)..." retry))
                           (apply #'pdd client origin-url `(:retry ,(1- retry) ,@args)))
                       ;; fail at last
                       (if pdd-debug (pdd-log tag "REQUEST FAILED: (%s) %s" url status))
                       (unwind-protect
                           (with-current-buffer (current-buffer)
                             (condition-case err
                                 (progn
                                   (when (string-match-p "error" (format "%s" (car status)))
                                     (pop status))
                                   (setq status (list (error-message-string (cons 'user-error status))))
                                   (if fail (pdd-funcall fail status) (signal 'user-error status)))
                               (error
                                (message "%s%s" (if pdd-abort-flag (format "[%s] " pdd-abort-flag) "") (error-message-string err)))))
                         ;; finally
                         (ignore-errors (funcall fine))))))
                  (dargs
                   (cl-loop for arg in
                            (if (or (null done) (equal (func-arity done) '(0 . many)))
                                '(a1)
                              (help-function-arglist done))
                            until (memq arg '(&rest &optional &key))
                            collect arg))
                  (donefn
                   (if (> (length dargs) 4)
                       (user-error "Function :done has invalid arguments")
                     `(lambda ,dargs
                        (if pdd-debug (pdd-log ,tag "Done!"))
                        (unwind-protect
                            (condition-case err
                                (with-current-buffer
                                    (if (and (buffer-live-p ,origin-buffer) (cl-plusp ,(length dargs)))
                                        ,origin-buffer
                                      (current-buffer))
                                  (,(or done 'identity) ,@dargs))
                              (error (setq pdd-abort-flag 'done)
                                     (funcall ,failfn err)))
                          (ignore-errors (funcall ,fine))))))
                  (filterfn
                   (when filter
                     (lambda ()
                       ;; abort action and error case
                       (condition-case err
                           (unless pdd-abort-flag
                             (if (zerop (length (help-function-arglist filter)))
                                 ;; with no argument
                                 (funcall filter)
                               ;; arguments maybe: (headers), (headers process)
                               (pdd-funcall filter
                                 (list (save-excursion
                                         (save-restriction
                                           (widen)
                                           (pdd-extract-http-headers)))
                                       (get-buffer-process (current-buffer))))))
                         (error
                          (if pdd-debug (pdd-log tag "Error in filter: (%s) %s" url err))
                          (setq pdd-abort-flag 'filter)
                          (funcall failfn err)))))))
             (apply #'cl-call-next-method client url `(:fail ,failfn :filter ,filterfn :done ,donefn ,@args))))
  (declare (indent 1)))


;;; Implement of url.el

(defclass pdd-url-client (pdd-client)
  ((proxy-services
    :initarg :proxies
    :initform nil
    :type (or list null)
    :documentation "Proxy services passed to `url.el', see `url-proxy-services' for details."))
  :documentation "Http Client implemented using `url.el'.")

(defvar url-http-content-type)
(defvar url-http-end-of-headers)
(defvar url-http-transfer-encoding)
(defvar url-http-response-status)
(defvar url-http-response-version)
(defvar url-http-codes)

(defvar pdd-url-extra-filter nil)

(defun pdd-url-http-extra-filter (beg end len)
  "Call `pdd-url-extra-filter'.  BEG, END and LEN see `after-change-functions'."
  (when (and pdd-url-extra-filter (bound-and-true-p url-http-end-of-headers)
             (if (equal url-http-transfer-encoding "chunked") (= beg end) ; when delete
               (= len 0))) ; when insert
    (save-excursion
      (save-restriction
        (narrow-to-region url-http-end-of-headers (point-max))
        (funcall pdd-url-extra-filter)))))

(cl-defmethod pdd ((client pdd-url-client) url &key method
                   params headers data resp filter done fail fine timeout sync retry)
  "Send a request with CLIENT.
See the generic method for args URL, METHOD, PARAMS, HEADERS, DATA, RESP,
FILTER, DONE, FAIL, FINE, TIMEOUT, SYNC and RETRY and more."
  (ignore params fine retry)
  (let* ((tag (eieio-object-class client))
         (url-user-agent (or (oref client user-agent) pdd-user-agent))
         (url-proxy-services (or (oref client proxy-services) url-proxy-services))
         (rdata (pdd-transform-request data headers))
         (url-request-data (car rdata))
         (url-request-extra-headers (cadr rdata))
         (url-request-method (string-to-unibyte (upcase (format "%s" method))))
         (url-mime-encoding-string "identity")
         (get-resp-content
          (lambda ()
            ;; after around, the :done is always exist
            (unless (zerop (car (func-arity done)))
              ;; set multibyte here, just to unify with plz.el
              (set-buffer-multibyte (not (pdd-binary-type-p url-http-content-type)))
              (let ((bs (buffer-substring-no-properties
                         (min (1+ url-http-end-of-headers) (point-max)) (point-max)))
                    (hs (pdd-extract-http-headers)))
                (list (pdd-transform-response bs (or resp hs))
                      hs url-http-response-status url-http-response-version)))))
         data data-buffer timer)
    (when pdd-debug
      (pdd-log tag "%s %s" url-request-method url)
      (pdd-log tag "HEADER: %S" url-request-extra-headers)
      (pdd-log tag "DATA: %s" url-request-data)
      (pdd-log tag "Proxy: %s" url-proxy-services)
      (pdd-log tag "User Agent: %s" url-user-agent)
      (pdd-log tag "MIME Encoding: %s" url-mime-encoding-string))
    (let* ((errorh
            (lambda (status)
              (cond
               ((null status)
                (setq pdd-abort-flag 'conn)
                (list 'bad-request "Maybe something wrong with network"))
               ((or (null url-http-end-of-headers) (= 1 (point-max)))
                (setq pdd-abort-flag 'conn)
                (list 'empty-response "Nothing responsed from server"))
               (t
                (setq pdd-abort-flag 'resp)
                (let* ((err (plist-get status :error))
                       (code (caddr status))
                       (desc (caddr (assoc code url-http-codes))))
                  (if desc (setf (cadr err) desc))
                  err)))))
           (callback
            (lambda (status)
              (ignore-errors (cancel-timer timer))
              (setq data-buffer (current-buffer))
              (remove-hook 'after-change-functions #'pdd-url-http-extra-filter t)
              (unless pdd-abort-flag
                (unwind-protect
                    (if-let* ((err (funcall errorh status)))
                        (funcall fail err)
                      (setq data (pdd-funcall done (funcall get-resp-content))))
                  (unless sync (kill-buffer data-buffer))))))
           (proc-buffer (url-retrieve url callback nil t))
           (process (get-buffer-process proc-buffer)))
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
                       (setq-local url-http-end-of-headers 52)
                       (insert "HTTP/1.1 504 Operation timeout\nContent-Length: 17\n\nOperation timeout")))
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
            data)
        process))))


;;; Implement of plz.el

(defclass pdd-plz-client (pdd-client)
  ((extra-args
    :initarg :args
    :type list
    :documentation "Extra arguments passed to curl program."))
  :documentation "Http Client implemented using `plz.el'.")

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
Or switch http client to `pdd-url-client' instead:\n
  (setq pdd-default-client (pdd-url-client))")

(cl-defmethod pdd :before ((_ pdd-plz-client) &rest _)
  "Check if `plz.el' is available."
  (unless (and (require 'plz nil t) (executable-find plz-curl-program))
    (error "You should have `plz.el' and `curl' installed before using `pdd-plz-client'")))

(cl-defmethod pdd ((client pdd-plz-client) url &key method
                   params headers data resp filter done fail fine timeout sync retry)
  "Send a request with CLIENT.
See the generic method for args URL, METHOD, PARAMS HEADERS, DATA, RESP,
FILTER, DONE, FAIL, FINE, TIMEOUT, SYNC and RETRY and more."
  (ignore params fine retry)
  (let* ((tag (eieio-object-class client))
         (rdata (pdd-transform-request data headers))
         (abort-flag) ; used to catch abort action from :filter
         (plz-curl-default-args (if (slot-boundp client 'extra-args)
                                    (append (oref client extra-args) plz-curl-default-args)
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
         (string-or-binary
          (lambda () ; decode according content-type. there is no builtin way to do this in plz
            (unless pdd-abort-flag
              (widen)
              (goto-char (point-min))
              ;; Clean the ^M, make it same as in url.el
              (save-excursion
                (while (search-forward "\r" nil :noerror) (replace-match "")))
              ;; don't wasting time on decode/extract when :done without args
              (unless (zerop (car (func-arity done)))
                (unless (looking-at plz-http-response-status-line-regexp)
                  (signal 'plz-http-error
                          (list "Unable to parse HTTP response status line"
                                (buffer-substring (point) (line-end-position)))))
                ;; have to extract headers for body decode, waste but works
                (let* ((http-version (string-to-number (match-string 1)))
                       (status-code (string-to-number (match-string 2)))
                       (headers (pdd-extract-http-headers))
                       (content-type (alist-get 'content-type headers))
                       (binaryp (pdd-binary-type-p content-type)))
                  (set-buffer-multibyte (not binaryp))
                  (goto-char (point-min))
                  (unless (re-search-forward plz-http-end-of-headers-regexp nil t)
                    (signal 'plz-http-error '("Unable to find end of headers")))
                  (narrow-to-region (point) (point-max))
                  ;; hard code 'utf-8. any scences that not it?
                  (unless binaryp (decode-coding-region (point-min) (point-max) 'utf-8))
                  ;; pass all these data to done. pity elisp has no values mechanism
                  (list (pdd-transform-response (buffer-string) (or resp headers))
                        headers status-code http-version))))))
         (raise-error
          (lambda (err)
            ;; hacky, but try to unify the error styles with url.el
            (when (and (consp err) (memq (car err) '(plz-http-error plz-curl-error)))
              (setq err (caddr err)))
            (when (plz-error-p err)
              (setq err
                    (or (plz-error-message err)
                        (when-let* ((curl (plz-error-curl-error err)))
                          (list 'curl-error
                                (concat (format "%s" (or (cdr curl) (car curl)))
                                        (pcase (car curl)
                                          (2 (when (memq system-type '(cygwin windows-nt ms-dos))
                                               pdd-plz-initialize-error-message))))))
                        (when-let* ((res (plz-error-response err)))
                          (list 'http (plz-response-status res) (plz-response-body res))))))
            ;; :fail has been decorated, it's non-nil and have a required argument
            (funcall fail err))))
    ;; data and headers
    (setq data (car rdata) headers (cadr rdata))
    (unless (alist-get "User-Agent" headers nil nil #'string-equal-ignore-case)
      (push `("User-Agent" . ,(or (oref client user-agent) pdd-user-agent)) headers))
    ;; log
    (when pdd-debug
      (pdd-log tag "%s" url)
      (pdd-log tag "HEADER: %s" headers)
      (pdd-log tag "DATA: %s" data)
      (pdd-log tag "EXTRA: %s" plz-curl-default-args))
    ;; sync
    (if sync
        (condition-case err
            (let ((res (plz method url
                         :headers headers
                         :body data
                         :body-type (if (caddr rdata) 'binary 'text)
                         :decode nil
                         :as string-or-binary
                         :filter filter-fn
                         :then 'sync
                         :timeout timeout)))
              (unless abort-flag (pdd-funcall done res)))
          (error (funcall raise-error err)))
      ;; async
      (plz method url
        :headers headers
        :body data
        :body-type (if (caddr rdata) 'binary 'text)
        :decode nil
        :as string-or-binary
        :filter filter-fn
        :then (lambda (res) (unless pdd-abort-flag (pdd-funcall done res)))
        :else (lambda (err) (funcall raise-error err))
        :timeout timeout))))



(defvar pdd-default-client
  (if (and (require 'plz nil t) (executable-find plz-curl-program))
      (pdd-plz-client)
    (pdd-url-client))
  "Client used by `pdd' by default.
This should be instance of symbol `pdd-client', or a function with current
url or url+method as arguments that return an instance.  If is a function,
the client be used will be determined dynamically when the `pdd' be called.")

(defun pdd-ensure-default-client (args)
  "Pursue the value of variable `pdd-default-client' if it is a function.
ARGS should be the arguments of function `pdd'."
  (if (functionp pdd-default-client)
      (pcase (car (func-arity pdd-default-client))
        (1 (funcall pdd-default-client (car args)))
        (2 (funcall pdd-default-client (car args)
                    (intern-soft
                     (or (plist-get (cdr args) :method)
                         (if (plist-get (cdr args) :data) 'post 'get)))))
        (_ (user-error "If `pdd-default-client' is a function, it can only have
one argument (url) or two arguments (url method)")))
    pdd-default-client))

(defun pdd-complete-absent-keywords (&rest args)
  "Add the keywords absent for ARGS used by function `pdd'."
  (let* ((pos (or (cl-position-if #'keywordp args) (length args)))
         (fst (cl-subseq args 0 pos))
         (lst (cl-subseq args pos))
         (take (lambda (fn) (if-let* ((p (cl-position-if fn fst))) (pop (nthcdr p fst)))))
         (url (funcall take (lambda (arg) (and (stringp arg) (string-prefix-p "http" arg)))))
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
  "Send a request with `pdd-default-client'.
In this case, the first argument in ARGS should be url instead of client.
See the generic method for other ARGS and details."
  (let* ((args (apply #'pdd-complete-absent-keywords args))
         (client (pdd-ensure-default-client args)))
    (unless (and client (eieio-object-p client) (object-of-class-p client 'pdd-client))
      (user-error "Make sure `pdd-default-client' is available.  eg:\n
(setq pdd-default-client (pdd-url-client))\n\n\n"))
    (apply #'pdd client args)))

(provide 'pdd)

;;; pdd.el ends here
