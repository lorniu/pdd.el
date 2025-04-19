# HTTP library & Async Toolkit for Emacs

This package provides a robust and elegant library for HTTP requests and asynchronous operations in Emacs. It featuring a single, consistent API that works identically across different backends, maximizing code portability and simplifying development.

Core Strengths:

*   **Unified Backend:** Seamlessly utilize either the high-performance `curl` backend or the built-in `url.el`. It significantly enhances `url.el`, adding essential features like cookie-jar support, streaming support, multipart uploads, comprehensive proxy support (HTTP/SOCKS with auth-source integration), smart request/response data conversion and automatic retries.
*   **Developer Friendly:** Offers a `minimalist yet flexible API` that is backend-agnostic, intuitive and easy to use. Features like variadic callbacks and header abbreviations can help you achieve more with less code.
*   **Powerful Async Foundation:** Features a native, cancellable `Promise/A+` implementation and intuitive `async/await` syntax for clean, readable concurrent code. Includes integrated async helpers for `timers` and external `processes`. Also includes a `queue` mechanism for fine-grained concurrency control when making multiple asynchronous requests.
*   **Highly Extensible:** Easily customize request/response flows using a clean transformer pipeline and object-oriented (EIEIO) backend design. This makes it easy to add new features or event entirely new backends.

Why this name?

> In my language, pdd is the meaning of "get the thing you want quickly"

Table of contents:
- [Usage](#Usage) · [API](#API) · [Examples](#Examples)
- [How to set `proxy`](docs/proxy.md) | [How to manage `cookies`](docs/cookie-jar.md) | [Control concurrency with `:queue`](docs/queue.md)
- [The power of Promise and Async/Await `(pdd-task)`](docs/task-and-async-await.md)
- [Integrate `timers` with task and request](docs/task-timers.md)
- [Integrate `make-process` with task and request](docs/task-process.md)
- [Compare this package with plz.el](#Comparison)  |  [Who is faster, url.el or plz.el?](docs/queue.md#example-who-is-faster-urlel-or-plzel)

## Installation

Download the `pdd.el` and place it in your `load-path`.

## Usage

The core of the library is function `pdd`:
``` emacs-lisp
;; Start a request

(pdd "https://httpbin.org/ip" ...)
(pdd (pdd-url-backend) "https://httpbin.org/ip" ...) ; explicit backend

;; If no http backend specified, then `pdd-default-backend' will be used

(setq pdd-default-backend (pdd-url-backend))
(setq pdd-default-backend (pdd-url-backend :proxy "https://localhost:1088"))
(setq pdd-default-backend (pdd-curl-backend :proxy "socks5://127.0.0.1:1080"))

;; Dynamically determine backend with a function (&optional url method):

(setq pdd-default-backend
      (lambda (url method)
        (cond ((string-match-p "/image/" url)
               (pdd-curl-backend :proxy "socks5://127.0.0.1:1080"))
              ((eq method 'patch) (pdd-url-backend))
              (t (pdd-curl-backend)))))
```

And try to send requests like this:
``` emacs-lisp
;; By default, sync, get

(pdd "https://httpbin.org/user-agent")

;; Use :headers keyword to supply data sent in http header
;; Use :data keyword to supply data sent in http body
;; If :data is present, the :method 'post can be ignored

(pdd "https://httpbin.org/post"
  :headers '(("User-Agent" . "..."))
  :data '(("key" . "value")) ; or string "key=value&..." directly
  :method 'post)

;; If :done is present and :sync t is absent, the request will be asynchronous.
;; Perhaps sometimes you should specify :sync nil to make it more explicit.

(pdd "https://httpbin.org/post"
  :data '(("key" . "value"))
  :done (lambda (res) (message "%s" res)))

;; And with :fail to catch error

(pdd "https://httpbin.org/post"
  :data '(("key" . "value"))
  :done (lambda (res) (message "%s" res))
  :fail (lambda (err) (message "%s" err)))

;; Use `pdd-default-error-handler' to catch error when :fail is absent
;; Set its value globally, or just dynamically bind it with let

(let ((pdd-default-error-handler
       (lambda (err) (message "Crying for %s..." (caddr err)))))
  (pdd "https://httpbin.org/post-error"
    :data '(("key" . "value"))
    :done (lambda (res) (print res))))

;; Use :filter to provide logic while every chunk back (for stream feature)

(pdd "https://httpbin.org/post"
  :data '(("key" . "value"))
  :filter (lambda () (message "%s" (buffer-size)))
  :done (lambda (res) (message "%s" res)))

;; The callback :fine will run at last, no matter done or fail, everything is fine

(pdd "https://httpbin.org/post"
  :data '(("key" . "value"))
  :done (lambda (res) (messsage "%s" res))
  :fail (lambda (err) (message "%s" err))
  :fine (lambda () (message "kindness, please")))

;; Use :timeout to set how long one request can wait (seconds)
;; Use :retry to set times auto resend the request if timeout

(pdd "https://httpbin.org/ip" :done #'print :timeout 0.9 :retry 5)

;; Also, you can see, if the content-type is json, :data will be auto decoded,
;; If the response content-type is json, result string is auto converted to elisp object.
;; The data type, encoding and multibytes are transformed automatelly.

(pdd "https://httpbin.org/post"
  :params '(("name" . "jerry") ("age" . 8)) ; these will be concated to url
  :headers '(("Content-Type" . "application/json")) ; can use abbrev as :headers '(json)
  :data '(("key" . "value"))        ; this will be encoded to json string automatelly
  :done (lambda (res) (print res))) ; cause of auto conversion, `res' is an alist

;; If you don't want data be auto converted, wrap it with a function
;; If you don't want response be auto converted, use :as to override
(pdd "https://httpbin.org/post"
  :data (lambda () "some-data")
  :as #'identity :done (lambda (raw) ...))

;; Specific method

(pdd "https://httpbin.org/uuid")
(pdd "https://httpbin.org/patch" :method 'patch)
(pdd "https://httpbin.org/delete" :method 'delete)

;; Upload. Notice the difference: for file, not (a . path), but a list
;; like (name path) or (name path mime-type)

(pdd "https://httpbin.org/post"
  :data '((key1 . "hello")
          (key2 . "world")
          (file1 "~/aaa.xxx")
          (file2 "~/aaa.png" "image/png")))

;; Download, binary content will be auto detected, just save it

(with-temp-file "~/aaa.jpeg"
  (insert (pdd "https://httpbin.org/image/jpeg")))

(pdd "https://httpbin.org/image/jpeg"
  :done (lambda (r) ; async, non-block
          (with-temp-file "~/aaa.jpeg"
            (insert r))))
```

DONE and other callbacks have variadic arguments, use according their signatures:
``` emacs-lisp
;; Signature of DONE: (&key body headers code version request)
;; You can use specified arguments with &key in the callback arglist

(pdd "https://httpbin.org/ip" :done (lambda (&key body code) (list body code)))

;; For convenience, arguments can be treated as optional args,
;; and used in the order specified in the signature like this:

(pdd "https://httpbin.org/ip" :done (lambda () (message "hello")))
(pdd "https://httpbin.org/ip" :done (lambda (body) (message "IP: %s" (cdar body))))
(pdd "https://httpbin.org/ip" :done (lambda (_ headers code) (list headers code)))
(pdd "https://httpbin.org/ip" :done (lambda (body &key request) (list body request)))

;; FILTER: (&key headers process request)

(pdd "https://httpbin.org/ip" :filter (lambda () (get-buffer-process (current-buffer))))
(pdd "https://httpbin.org/ip" :filter (lambda (headers) (message "%s" headers)))
(pdd "https://httpbin.org/ip" :filter (lambda (&key request) (message "%s" request)))

;; FAIL: (&key text code error request)

(pdd "https://httpbin.org/ip7" :fail (lambda ()       (message "pity.")))
(pdd "https://httpbin.org/ip7" :fail (lambda (text)   (message "%s" text)))
(pdd "https://httpbin.org/ip7" :fail (lambda (_ code) (message "%s" code)))
(pdd "https://httpbin.org/ip7" :fail (lambda (&key error) (message "%s" error)))

;; FINE: (&optional request)

(pdd "https://httpbin.org/ip" :fine (lambda () (message "bye")))
(pdd "https://httpbin.org/ip" :fine (lambda (req) (message "url: %s" (oref req url))))

;; AS is used to preprocess the content to be passed to DONE,
;; If it's non-nil, it will override the default auto conversion behavior.
;; Signature: (&key body headers buffer)

(pdd "https://httpbin.org/ip"
  :as #'identity ; do nothing with the raw response body, just pass it to DONE
  :done (lambda (raw) (message "RAW: %s" raw)))

(pdd "https://httpbin.org/ip"
  :as (lambda () (current-buffer)) ; the context of as: process buffer
  :done (lambda (proc-buffer) ; the context of done: buffer starting the request
          (message "> work buffer: %s" (current-buffer))
          (message "> resp buffer: %s" proc-buffer)
          (with-current-buffer proc-buffer ; with the buffer, resolve yourself
            (message "> resp content: %s" (buffer-string)))))

;; Of cause, you can custom `as' type like this:

(cl-defmethod pdd-string-to-object ((_ (eql 'your-type)) string)
  (your-parse-logic string))
(pdd "https://example.com/site" :as 'your-type :done (lambda (your-obj) ...))
```

Of course, there are tricks that can make things easier:
``` emacs-lisp
;; The keywords :method, :data and :done can be omitted.
;; Just place url/method/data/done in any order before other keyword args.
;; Although not recommended, it is very convenient to send test requests this way

(pdd "https://httpbin.org/anything")
(pdd "https://httpbin.org/anything" #'print)
(pdd #'print "https://httpbin.org/anything")
(pdd 'delete "https://httpbin.org/delete")
(pdd '((key . value)) "https://httpbin.org/anything" #'print)
(pdd #'print 'put "https://httpbin.org/anything" '((key . value)) :timeout 2 :retry 3)
(pdd #'insert 'post "https://httpbin.org/anything" :as #'identity)

;; Another sugar is, you can simply code of :headers in the help of abbrevs.
;; See `pdd-header-rewrite-rules' for more details. For example:

(pdd "https://httpbin.org/anything"
  :headers `(("Content-Type" . "application/json")
             ("User-Agent" . "Emacs Agent")
             ("Authorization" ,(concat "Bearer " token))
             ("Accept" . "*/*"))
  :done (lambda (res) (print res)))

;; It can be simplied as:

(pdd 'print "https://httpbin.org/anything"
  :headers `(json ua-emacs (bear ,token) ("Accept" . "*/*")))

;; The data/headers/done/filter/timeout/retry can be dynamically bound.

(let ((pdd-default-sync nil)
      (pdd-default-retry 3)
      (pdd-default-headers `(json (bear ,token))))
  (pdd "https://httpbin.org/ip")            ; use default headers/data if exists
  (pdd "https://httpbin.org/uuid" :retry 1) ; override the default variables
  (pdd "https://httpbin.org/user-agent" :headers nil))

;; Therefore, defining a function for request with special settings is a good practice:

(defun my-request (&rest args)
  (let ((pdd-default-sync nil) (pdd-default-retry 3) (pdd-default-timeout 15) ;; ..
        (pdd-default-headers `(json (bear ,token)))
        (pdd-default-done (lambda (r) (message "> %s" r))))
    (apply #'pdd args)))
(my-request "https://httpbin.org/ip")
```

When handling multiple asynchronous requests, you may encounter **callback hell**, a tangled mess of nested callbacks. However, by using `pdd-task` and `pdd-async/await`, things become much easier ([more](docs/task-and-async-await.md)):
``` emacs-lisp
;; For example, request for ip and uuid, then use the results to send new request:

(pdd "https://httpbin.org/ip"
  :done (lambda (r1)
          (pdd "https://httpbin.org/uuid"
            :done (lambda (r2)
                    (pdd "https://httpbin.org/anything"
                      :data `((r1 . ,(alist-get 'origin r1))
                              (r2 . ,(alist-get 'uuid r2)))
                      :done (lambda (r3)
                              (message "> Got: %s"
                                       (alist-get 'form r3))))))))

;; You can simply it with async/await as:

(pdd-async
  (let* ((r1 (await (pdd "https://httpbin.org/ip")
                    (pdd "https://httpbin.org/uuid")))
         (r2 (await (pdd "https://httpbin.org/anything"
                      `((ip . ,(alist-get 'origin (car r1)))
                        (id . ,(alist-get 'uuid (cadr r1))))))))
    (message "> Got: %s" (alist-get 'form r2))))
```

To control concurreny or rate limit for multiple requests, use `queue` ([more](docs/queue.md)):
```emacs-lisp
(setq queue1 (pdd-queue :limit 7))
(pdd "https://httpbin.org/ip" :queue queue1)
```

Unified, simple and smart `proxy` config ([more](docs/proxy.md)):
```emacs-lisp
(pdd "https://httpbin.org/ip" :proxy "socks5://127.0.0.1:1080")
```

Cookies auto management with `cookie-jar` ([more](docs/cookie-jar.md)):
```emacs-lisp
(setq cookie-jar-1 (pdd-cookie-jar))
(pdd "https://httpbin.org/ip" :cookie-jar cookie-jar-1)
```

Use `:verbose` to inspect the request/response headers:
```emacs-lisp
(pdd "https://httpbin.org/ip" :verbose t)        ; show in message buffer
(pdd "https://httpbin.org/ip" :verbose #'insert) ; can be a function. here insert
```

## Examples

Download file with progress bar display:
``` emacs-lisp
;; Replace the url with a big file to have a try
;; you can abort the download by deleting the returned process

(let ((reporter (make-progress-reporter "Downloading...")))
  (pdd "https://httpbin.org/image/jpeg"
    :filter (lambda (headers)
              (let* ((total (string-to-number (alist-get 'content-length headers)))
                     (percent (format "%.1f%%" (/ (* 100.0 (buffer-size)) total))))
                (progress-reporter-update reporter percent)))
    :done (lambda (raw)
            (with-temp-file "~/aaa.jpeg"
              (insert raw)
              (progress-reporter-done reporter)))))
```

Scrape all images from a webpage:
```emacs-lisp
;; use `queue' to limit the concurrency to make sure success.
;; this code is not perfect, but it demonstrates how to do it.
;; also, the scrape is asynchronous, will not block emacs.

(defun my-scrape-site-images (url dir &optional concurrency-limit)
  (pdd-async
    (let* ((raw-html (await (pdd url)))
           (dom (with-temp-buffer
                  (require 'dom)
                  (insert raw-html)
                  (xml-remove-comments (point-min) (point-max))
                  (libxml-parse-html-region)))
           (urls (mapcar (lambda (img) (alist-get 'src (cadr img)))
                         (dom-by-tag dom 'img)))
           (pdd-base-url (let ((parsed (url-generic-parse-url url)))
                           (format "%s://%s" (url-type parsed) (url-host parsed))))
           (pdd-default-queue (pdd-queue :limit (or concurrency-limit 10)
                                         :fine (lambda () (message "Done.")))))
      (make-directory dir t)
      (dolist (url urls)
        (pdd url
          (lambda (r)
            (let ((coding-system-for-write 'no-conversion)
                  (loc (expand-file-name
                        (decode-coding-string
                         (url-unhex-string (file-name-nondirectory url)) 'utf-8)
                        dir)))
              (write-region r nil loc))))))))

(my-scrape-site-images
 "https://commons.wikimedia.org/wiki/Commons:Picture_of_the_Year/2022/R2/Gallery"
 "~/my-pdd-images/")
```

## API

``` emacs-lisp
(cl-defgeneric pdd (backend url &rest _args &key
                            method
                            params
                            headers
                            data
                            init
                            filter
                            as
                            done
                            fail
                            fine
                            sync
                            timeout
                            retry
                            proxy
                            queue
                            cookie-jar
                            verbose
                            &allow-other-keys)
  "Send HTTP request using the specified BACKEND.

This is a generic function with implementations provided by backend classes.

Parameters:
  BACKEND  - HTTP backend instance (subclass of `pdd-http-backend')
  URL      - Target URL (string)

Keyword Arguments:
  :METHOD  - HTTP method (symbol, e.g. `get, `post, `put), defaults to `get
  :PARAMS  - URL query parameters, accepts:
             * String - appended directly to URL
             * Alist - converted to key=value&... format
  :HEADERS - Request headers, supports formats:
             * Regular: ("Header-Name" . "value")
             * Abbrev symbols: json, bear (see `pdd-header-rewrite-rules')
             * Parameterized abbrevs: (bear "token")
  :DATA    - Request body data, accepts:
             * String - sent directly
             * Alist - converted to formdata or JSON based on Content-Type
             * File uploads: ((key filepath))
             * Function return a string, it will not be auto converted
  :INIT    - Function called before the request is fired by backend:
             (&optional request)
  :FILTER  - Filter function called during data reception, signature:
             (&key headers process request)
  :AS      - Preprocess results for DONE, accepts:
             * Symbol, process with `pdd-string-to-object' and `AS' as type
             * Function with signature (&key body headers buffer)
  :DONE    - Success callback, signature:
             (&key body headers code version request)
  :FAIL    - Failure callback, signature:
             (&key text code error request)
  :FINE    - Final callback (always called), signature:
             (&optional request)
  :SYNC    - Whether to execute synchronously (boolean)
  :TIMEOUT - Timeout in seconds
  :RETRY   - Number of retry attempts on timeout
  :PROXY   - Proxy used by current http request (string or function)
  :QUEUE   - Semaphore object used to limit concurrency (async only)
  :COOKIE-JAR - An object used to manage http cookies
  :VERBOSE - Display extra informations like headers when request, boolean/function

Returns:
  Response data in sync mode, task object in async mode.)
```

## Comparison

| Feature                     | pdd.el                           | plz.el                  |
|-----------------------------|----------------------------------|-------------------------|
| **Backend Support**         | Multiple (url.el + curl via plz) | curl only               |
| **Fallback Mechanism**      | ✅ Automatic fallback to url.el  | ❌ None (requires curl) |
| **Multipart Uploads**       | ✅ Support                       | ❌ No                   |
| **Encoding Handling**       | ✅ Auto detection and decoding   | ❌ Manual decode        |
| **Type Conversion**         | ✅ Auto conversion               | ❌️ Manual convert       |
| **Retry Logic**             | ✅ Configurable                  | ❌ None                 |
| **Req/Resp Interceptors**   | ✅ Support                       | ❌ None                 |
| **Proxy support**           | ✅ Dynamic and easy              | ⚠️ Manual               |
| **Auto Cookies manage**     | ✅ Support with cookie-jar       | ❌ No                   |
| **Promise integrated**      | ✅ Support                       | ❌ No                   |
| **Async/Await support**     | ✅ Support                       | ❌ No                   |
| **Header Abbreviations**    | ✅ Yes (e.g. `'(json bear)`)     | ❌ No                   |
| **Variadic Callbacks**      | ✅ Yes, make code cleaner        | ❌ No                   |
| **Streaming Support**       | ✅ Full                          | ✅ Full                 |
| **Error Handling**          | ✅ Robust                        | ✅ Robust               |
| **Customization**           | ✅ Extensive                     | ⚠️ Limited              |
| **Dependencies**            | None (url.el built-in)           | Requires curl binary    |

I used to think that `plz` was much faster than `url.el`. But after testing ([Who is faster, url.el or plz.el?](docs/queue.md#example-who-is-faster-urlel-or-plzel)), I found out that I am completely wrong.
In various situations, whether it's single concurrency or multiple concurrency, `plz` is at least 3 times as slow as `url.el`.

## Miscellaneous

Issues and PRs are welcome. Happy good day.
