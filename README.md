# HTTP Library for Emacs

A versatile HTTP client library that provides a unified interface making http requests across multiple backend implementations easily. It is designed for simplicity, flexibility and cross-platform compatibility.

 - Choose between built-in `url.el` or high-performance `curl` backends. It gracefully falls back to `url.el` when `curl` is unavailable without requiring code changes.
 - Rich feature set including multipart uploads, streaming support, cookie-jar support, automatic retry strategies, and smart data conversion. Enhances `url.el` to support all these capabilities and work well enough.
 - Minimalist yet intuitive API that works consistently across backends. Features like variadic callbacks and header abbreviation rules help you accomplish more with less code.
 - Extensible architecture makes it easy to add new backends.

Table of contents:
- [Usage](#Usage) · [API](#API) · [Examples](#Examples)
- [How to manage cookies](docs/cookie-jar.md)
- [Compare with plz.el](#Comparison)

Why this name?

> In my language, pdd is the meaning of "get the thing you want quickly"

## Installation

Just download the `pdd.el` and place it in your `load-path`.

> Notice: package `plz` is optionally. At present, if you prefer to use `curl` to send requests, make sure both `curl` and `plz` are available first.

## Usage

Just request through `pdd`, with or without specifying an http backend:
``` emacs-lisp
(pdd "https://httpbin.org/user-agent" ...)
(pdd (pdd-url-backend) "https://httpbin.org/user-agent" ...)

;; If request with no http backend specified, the request will be sent
;; through backend specified by `pdd-default-backend'.

;; You can config it. If not, it will use `(pdd-plz-backend)` if possible,
;; then fallback to `(pdd-url-backend)` if `plz` is unavailable.
(setq pdd-default-backend (pdd-url-backend))
(setq pdd-default-backend (pdd-plz-backend :args '("--proxy" "socks5://127.0.0.1:1080")))
(setq pdd-default-backend (pdd-url-backend :proxies '(("http"  . "host:9999")
                                                      ("https" . "host:9999"))))

;; Use a function to dynamically determine which backend to use for a request
;; The function can have one argument (url), or two arguments (url method)
(setq pdd-default-backend
      (lambda (url)
        (if (string-match-p "deepl.com/" url)
            (pdd-plz-backend :args '("--proxy" "socks5://127.0.0.1:1080"))
          (pdd-plz-backend))))
(setq pdd-default-backend
      (lambda (_ method)
        (if (eq method 'patch) (pdd-url-backend) (pdd-plz-backend))))
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

;; If :done is present and :sync t is absent, the request will be asynchronous!
(pdd "https://httpbin.org/post"
  :data '(("key" . "value"))
  :done (lambda (res) (message "%s" res)))

;; And with :fail to catch the error
(pdd "https://httpbin.org/post"
  :data '(("key" . "value"))
  :done (lambda (res) (message "%s" res))
  :fail (lambda (err) (message "%s" err)))

;; Use `pdd-default-error-handler' to catch error when :fail is absent
;; Set its value globally, or just dynamically bind it with let
(let ((pdd-default-error-handler
       (lambda (_ code) (message "Crying for %s..." code))))
  (pdd "https://httpbin.org/post-error"
    :data '(("key" . "value"))
    :done (lambda (res) (print res))))

;; Use :filter to provide logic as every chunk back (for stream feature)
;; It is a function with no arguments, or headers, or headers and process as arguments
(pdd "https://httpbin.org/post"
  :data '(("key" . "value"))
  :filter (lambda () (message "%s" (buffer-size)))
  :done (lambda (res) (message "%s" res)))

;; The function :fine will run at last, no matter done or fail, everything is fine
(pdd "https://httpbin.org/post"
  :data '(("key" . "value"))
  :done (lambda (res) (messsage "%s" res))
  :fail (lambda (err) (message "%s" err))
  :fine (lambda () (message "kindness, please")))

;; Use :timeout to set how long one request can wait (seconds)
;; Use :retry to set times auto resend the request if timeout
(pdd "https://httpbin.org/ip"
  :done #'print :timeout 0.9 :retry 5)

;; Also, you can see, if the content-type is json, :data will be auto decoded,
;; If the response content-type is json, result string is auto parsed to elisp object
;; The data type, encoding and multibytes are transformed automatelly all the time
(pdd "https://httpbin.org/post"
  :params '(("name" . "jerry") ("age" . 8)) ; these will be concated to url
  :headers '(("Content-Type" . "application/json")) ; can use abbrev as :headers '(json)
  :data '(("key" . "value"))          ; this will be encoded to json string automatelly
  :done (lambda (json) (print json))) ; cause of auto parse, the argument `json' is an alist

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

;; Download
(with-temp-file "~/aaa.jpeg"
  (insert (pdd "https://httpbin.org/image/jpeg")))
```

 Done and other callbacks have dynamical number of arguments. Pass according signatures described below:
``` emacs-lisp
;; Arguments of done: (&optional body headers status-code http-version request-instance)
;; If 0 argument, current buffer is process buffer, otherwise is working buffer
(pdd "https://httpbin.org/ip" :done (lambda () (message "%s" (buffer-string))))
(pdd "https://httpbin.org/ip" :done (lambda (body) (message "IP: %s" (cdar body))))
(pdd "https://httpbin.org/ip" :done (lambda (_body headers) (print headers)))
(pdd "https://httpbin.org/ip" :done (lambda (_ _ status-code) (print status-code)))
(pdd "https://httpbin.org/ip" :done (lambda (_ _ _ http-version) (message http-version)))
(pdd "https://httpbin.org/ip" :done (lambda (_ _ _ _ req) (message "%s" (oref req url))))

;; Arguments of filter: (&optional response-headers process request-instance)
(pdd "https://httpbin.org/ip" :filter (lambda () (get-buffer-process (current-buffer))))
(pdd "https://httpbin.org/ip" :filter (lambda (headers) (message "%s" headers)))

;; Arguments of fail: (&optional error-message http-status error-object request-instance)
(pdd "https://httpbin.org/ip7" :fail (lambda ()       (message "pity.")))
(pdd "https://httpbin.org/ip7" :fail (lambda (msg)    (message "%s" msg)))
(pdd "https://httpbin.org/ip7" :fail (lambda (_ code) (message "%s" code)))

;; Arguments of fine: (&optional request-instance)
(pdd "https://httpbin.org/ip" :fine (lambda () (message "bye")))
(pdd "https://httpbin.org/ip" :fine (lambda (req) (message "url: %s" (oref req url))))
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
(pdd #'insert 'post "https://httpbin.org/anything" :resp #'identity)

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

## API

``` emacs-lisp
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
  BACKEND  - HTTP backend instance (subclass of `pdd-backend')
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
  Response data in sync mode, process object in async mode.)
```

## Comparison

| Feature                   | pdd.el                           | plz.el                  |
|---------------------------|----------------------------------|-------------------------|
| **Backend Support**       | Multiple (url.el + curl via plz) | curl only               |
| **Fallback Mechanism**    | ✅ Automatic fallback to url.el  | ❌ None (requires curl) |
| **Multipart Uploads**     | ✅ Support                       | ❌ No                   |
| **Encoding Handling**     | ✅ Auto detection and decoding   | ❌ Manual decode        |
| **Type Conversion**       | ✅ Auto conversion               | ❌️ Manual convert       |
| **Retry Logic**           | ✅ Configurable                  | ❌ None                 |
| **Req/Resp Interceptors** | ✅ Support                       | ❌ None                 |
| **Auto Cookies manage**   | ✅ Support with cookie-jar       | ❌ No                   |
| **Header Abbreviations**  | ✅ Yes (e.g. `'(json bear)`)     | ❌ No                   |
| **Variadic Callbacks**    | ✅ Yes, make code cleaner        | ❌ No                   |
| **Streaming Support**     | ✅ Full                          | ✅ Full                 |
| **Error Handling**        | ✅ Robust                        | ✅ Robust               |
| **Sync/Async Modes**      | ✅ Both supported                | ✅ Both supported       |
| **Customization**         | ✅ Extensive                     | ⚠️ Limited              |
| **Dependencies**          | None (url.el built-in)           | Requires curl binary    |

## Miscellaneous

Issues and PRs are welcome. Happy good day.
