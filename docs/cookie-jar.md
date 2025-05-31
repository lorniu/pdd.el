# Tutorial of Cookie Jar

`pdd` provides a complete cookie management system based on cookie-jar that automates the handling of cookies in HTTP requests and responses.

The main features include:
- Auto storage of cookies returned by the server
- Auto sends the appropriate cookies in requests
- Auto cookie expiration management
- Support auto persistent storage of cookies

## Basic usage

Create cookie-jar:

```emacs-lisp
;; new jar
(pdd-cookie-jar)

;; jar with initial value: alist of (domain . cookie-list) where each cookie is a plist
(pdd-cookie-jar :cookies '(("example.com" ((:name "sess.id" :value "333")))))

;; jar with persist file. It will try to load cookies from file first, and then sync the file with the jar all the time
(pdd-cookie-jar :persist "~/cookies-aaa"))

;; Example, create a cookie-jar for bilibili.com with cookies-string from browser as initial value
(pdd-cookie-jar :persist "~/cookies-bilibili"
                :cookies (list "bilibili.com"
                               (pdd-parse-request-cookies
                                 "buvid4=7F17..; DedeUserID=2571691..")))
```

Use cookie-jar in request:

```emacs-lisp
(setq my-cookie-jar (pdd-cookie-jar))

(pdd "https://example.com/login"
  :cookie-jar my-cookie-jar ; bind the cookie-jar this way
  :data '((username . "user") (password . "pass"))
  :done (lambda (data) (message "Login success!")))

(pdd "https://example.com/profile"
  :cookie-jar my-cookie-jar ; cookies will be managed automatically in future requests
  :done (lambda (data) (message "Profile: %S" data)))

;; inspect cookie headers with :verbose t
(setq cj-1 (pdd-cookie-jar))
(pdd "https://bing.com" :done #'ignore :cookie-jar cj-1 :verbose t)
```

Use `pdd-active-cookie-jar` to make things easier:

```emacs-lisp
(setq pdd-active-cookie-jar (pdd-cookie-jar :persist "~/cookies.txt"))

;; All requests without cookie-jar bound will use the default cookie-jar if possible

(pdd "https://example.com/api"
  :done (lambda (data) (message "Data: %S" data)))
```

But global default cookie-jar is not recommended, try dynamic binding:

```emacs-lisp
(let ((pdd-active-cookie-jar (pdd-cookie-jar :persist "~/cookies-aaa.text")))
  (pdd "https://example.com/profile"))

(let ((pdd-active-cookie-jar (pdd-cookie-jar :persist "~/cookies-bbb.text")))
  (pdd "https://example.com/profile"))

(let ((pdd-active-cookie-jar nil)) ; force disable cookies
  (pdd "https://example.com/profile"))

;; It's better to wrap the binding in your own request function

(defvar my-cookie-jar (pdd-cookie-jar :persist "~/cookies.text"))

(defun my-request (&rest args)
  (let ((pdd-active-cookie-jar my-cookie-jar))
    (apply #'pdd args)))

(my-request "https://example.com/profile"
  :done (lambda (data) (message "Profile: %S" data)))
```

You can use a function instead of instance to dynamic dispatch different cookie-jars to different requests:

```emacs-lisp
(defvar jar-aaa (pdd-cookie-jar))
(defvar jar-bbb (pdd-cookie-jar))

(setq pdd-active-cookie-jar
      (lambda (request)
        (with-slots (url) request
          (cond ((string-match-p "httpbin.org" url)
                 jar-aaa) ; notice: return a ref instead of creating a new instance
                ((string-match-p "example.org" url)
                 jar-bbb)))))

(pdd "https://httpbin.org/ip")  ; this will use jar-aaa
(pdd "https://example.org/ip")  ; this will use jar-bbb
(pdd "https://othersite.com")   ; this will not use cookie
```

The management of Cookies is automatic. If you need Cookies support, just bind a cookie-jar to the request, and need to do anything else.

## Manual management

```emacs-lisp
;; add new cookie (with RFC 6265 format)
(pdd-cookie-jar-put jar "example.com"
  (list :name "session_id"
        :value "abc123"
        :path "/"
        :expires (time-add (current-time) (days-to-time 30))))

;; add new cookies from browser's cookie string
(pdd-cookie-jar-put jar "example.com"
  (pdd-parse-request-cookies "aaa=3;bbb=4"))

;; query cookie
(let ((cookies (pdd-cookie-jar-get jar "example.com" "/api" t)))
  (message "Cookies for example.com: %S" cookies))

(pdd-cookie-jar-persist jar)             ; save
(pdd-cookie-jar-load jar)                ; load
(pdd-cookie-jar-clear jar)               ; clear expires
(pdd-cookie-jar-clear jar t)             ; clear all contents
(pdd-cookie-jar-clear jar "example.com") ; clear only domain
```

## Miscellaneous

This cookie system is designed to work automatically. In most cases, you only need to bind the cookie jar, and then the request will handle the cookies automatically. For scenarios that require more precise control, manual management can be done.

The persistence file of the cookies may contain sensitive information, please keep it safe.

For high-frequency request scenarios, it is recommended to use memory-based jar (without setting the `:persist` parameter).
