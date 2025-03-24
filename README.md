# HTTP Library Adapter for Emacs.

It support `url.el` and [plz.el](https://github.com/alphapapa/plz.el), and can be extended.

- Its API is simple and uniform
- Support both **sync/async** request
- Support **streaming** request
- Support **retry** for timeout
- Support **proxies** configuration
- Support file **upload/download**

> In my language, pdd is the meaning of "get the thing you want quickly"

## Installation

Just download the `pdd.el` and place it in your `load-path`.

> Notice: package `plz` is optionally. At present, if you prefer to use `curl` to send requests, make sure both `curl` and `plz` are available first.

## Usage

Just request through `pdd`, with or without specifying an http client:
``` emacs-lisp
(pdd "https://httpbin.org/user-agent" ...)
(pdd (pdd-plz-client) "https://httpbin.org/user-agent" ...)

;; If request with no http client specified, the request will be sent
;; through client specified by `pdd-default-client'.

;; You can config it. If not, it will use `(pdd-plz-client)` if possible,
;; then fallback to `(pdd-url-client)` if `plz` is unavailable.
(setq pdd-default-client (pdd-url-client))
(setq pdd-default-client (pdd-plz-client :args '("--proxy" "socks5://127.0.0.1:1080")))
(setq pdd-default-client (pdd-url-client :proxies '(("http"  . "host:9999")
                                                    ("https" . "host:9999"))))

;; Use a function to dynamically determine which client to use for a request
;; The function can have one argument (url), or two arguments (url method)
(setq pdd-default-client
      (lambda (url)
        (if (string-match-p "deepl.com/" url)
            (pdd-plz-client :args '("--proxy" "socks5://127.0.0.1:1080"))
          (pdd-plz-client))))
(setq pdd-default-client
      (lambda (_ method)
        (if (eq method 'patch) (pdd-url-client) (pdd-plz-client))))
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
  :done (lambda (res) (print res)))

;; And with :fail to catch the error
(pdd "https://httpbin.org/post"
  :data '(("key" . "value"))
  :done (lambda (res) (print res))
  :fail (lambda (err) (message "%s" err)))

;; Use `pdd-default-error-handler' to catch error when :fail is absent
;; Set its value globally, or just dynamically bind it with let
(let ((pdd-default-error-handler
       (lambda (_ code) (message "Crying for %s..." code))))
  (pdd "https://httpbin.org/post-error"
    :data '(("key" . "value"))
    :done (lambda (res) (print res))))

;; Use :timeout to set how long one request can wait (seconds)
;; Use :retry to set times auto resend the request if timeout (for async only)
;; Also, you can see, if the content-type is json, :data will be auto decoded,
;; If the response content-type is json, result string is auto parsed to elisp object
;; So, for RESTful, what you need is just specify the correct json content-type
(pdd "https://httpbin.org/post"
  :params '(("name" . "jerry") ("age" . 8)) ; these will be concated to url
  :headers '(("Content-Type" . "application/json")) ; can use abbrev as :headers '(json)
  :data '(("key" . "value"))         ; this will be encoded to json string automatelly
  :done (lambda (json) (print json)) ; cause of auto parse, the argument `json' is an alist
  :timeout 0.9 :retry 5)

;; Use :filter to provide logic as every chunk back (for stream feature)
;; It is a function with no arguments, or headers, or headers and process as arguments
(pdd "https://httpbin.org/post"
  :data '(("key" . "value"))
  :filter (lambda () (message "%s" (buffer-size)))
  :done (lambda (res) (print res)))

;; The function :fine will run at last, no matter done or fail, everything is fine
(pdd "https://httpbin.org/post"
  :data '(("key" . "value"))
  :done (lambda (res) (print res))
  :fail (lambda (err) (message "%s" err))
  :fine (lambda () (message "kindness, please")))

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

;; Arguments of :done are smart, it can be zero, one, two, three or four
;; If zero argument, current buffer is the one with raw responsed string
(pdd "https://httpbin.org/ip" :done (lambda () (message "%s" (buffer-string))))
(pdd "https://httpbin.org/ip" :done (lambda (body) (message "IP: %s" (cdar body))))
(pdd "https://httpbin.org/ip" :done (lambda (_body headers) (print headers)))
(pdd "https://httpbin.org/ip" :done (lambda (_ _ status-code) (print status-code)))
(pdd "https://httpbin.org/ip" :done (lambda (_ _ _ http-version) (print http-version)))

;; Arguments of :filter and :fail are dynamical too
(pdd "https://httpbin.org/ip" :fail (lambda () (message "pity.")))
(pdd "https://httpbin.org/ip" :fail (lambda (err-msg) (message "%s" err-msg)))
(pdd "https://httpbin.org/ip" :fail (lambda (_ http-code) (message "%s" http-code)))
(pdd "https://httpbin.org/ip" :filter (lambda () (get-buffer-process (current-buffer))))
(pdd "https://httpbin.org/ip" :filter (lambda (headers) (message "%s" headers)))
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
  :done #'print)
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
  - METHOD: Request method, symbol like 'post.  If nil guess by data.
  - HEADERS: Additional headers to include in the request.  Alist.
  - DATA: The data to include in the request.  If this is a string, it will be
          sent directly as request body.  If this is a list and every element
          is (key . value) then this will be joined to a string like a=1&b=2 and
          then be sent.  If this is a list and some element is (key filename)
          format, then the list will be normalized as multipart formdata string
          and be sent.
  - RESP: Whether or how to auto encode the response content.
          Currently this should a function with responsed string as argument.
          For example, make this with value #'identity should make
          the raw responsed string is passed to DONE without any parsed.
  - FILTER: A function to be called every time when some data returned.
  - DONE: A function to be called when the request succeeds.
  - FAIL: A function to be called when the request fails.
  - FINE: A function to be called at last, no matter done or fail.
  - RETRY: How many times it can retry for timeout.  Number.
  - TIMEOUT: Set connect timeout for request.  Number.
  - SYNC: Non-nil means request synchronized.  Boolean.

If request async, return the process behind the request."）
```

## Miscellaneous

Issues and PRs are welcome. Happy good day.
