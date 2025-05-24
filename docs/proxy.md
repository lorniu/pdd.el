# Tutorial of Proxy

All proxies are configured with URL format string like this:
```shell
# http proxy
http://127.0.0.1:1081
http://user:pass@127.0.0.1:1081

# socks4, socks4a or socks5
socks4://127.0.0.1:1080
socks5://user:pass@127.0.0.1:1080
```

## Basic usage

Configure proxies support different levels:

```emacs-lisp
;; Per-Request Proxy:
(pdd "https://httpbin.org/ip"
  :proxy "socks5://127.0.0.1:1080")

;; Per-Backend Proxy:
(setq aaa (pdd-url-backend :proxy "http://127.0.0.1:1080"))
(setq aaa (pdd-url-backend :proxy "socks5://127.0.0.1:1080"))
(pdd aaa "https://httpbin.org/ip")

;; Global Default Proxy:
(setq pdd-proxy "socks5://127.0.0.1:1080")
```

To make proxy smarter, use a function instead of the url string, the function signature is (&optional request backend).

```emacs-lisp
;; Just return a url format string as proxy
(setq pdd-proxy (lambda () "https://proxy:1080"))

;; You can do much more in the function
(setq pdd-proxy
      (lambda (request)
        (with-slots (url) request
          (cond
           ((string-match-p "localhost\\|127\\.0" url) nil)
           ((string-match-p "httpbin") "http://localhost:8080")
           (t (getenv "HTTPS_PROXY"))))))
```

If the proxy need authorization, embed the credentials into url:
```emacs-lisp
;; URL-Embedded Credentials

(setq pdd-proxy "http://tom:666@127.0.0.1:1080")

;; Configure in ~/.authinfo:
;; machine proxy.example.com port 8080 login user password pass

(setq pdd-proxy "http://user@proxy.example.com:8080")

;; Programmatic Credential Resolution:

(setq pdd-proxy
      (lambda (request)
        (let ((creds (lookup-credentials (oref request url))))
          (format "http://%s:%s@proxy:8080" (car creds) (cdr creds)))))
```

## Advanced Examples

Backend-Specific Proxies:
```emacs-lisp
(setq pdd-proxy
      (lambda (_ backend)
        (if (cl-typep backend 'pdd-url-backend)
            "https://127.0.0.1:1081"
          "socks5://127.0.0.1:1080")))
```

Protocol-Specific Proxies:
```emacs-lisp
(setq pdd-proxy
      (lambda (req)
        (pcase (url-type (url-generic-parse-url (oref req url)))
          ("https" "http://ssl-proxy:8080")
          ("http"  "http://plain-proxy:8080")
          ("ftp"   "socks5://ftp-gateway:1080"))))
```

Traffic Shaping:
```emacs-lisp
(setq pdd-proxy
      (lambda (request)
        (with-slots (data) request
          ;; Route large uploads through high-bandwidth proxy
          (if (> (length data) (* 10 1024 1024))  ; 10MB threshold
              "http://bulk-upload-proxy:8080"
            "http://standard-proxy:8080"))))
```

Failover Proxies (can extend to a proxy pool):
```emacs-lisp
(defvar pdd-proxy-list
  '("http://primary:8080" "http://secondary:8080"))

(setq pdd-proxy
      (lambda ()
        (cl-loop for proxy in (sort pdd-proxy-list #'proxy-priority)
                 when (proxy-available-p proxy)
                 return proxy)))
```

## Notice for `pdd-url-backend`

- Although patches can make _socks proxy over tls_ work, it is usually fragile. Hoping that one day this can be fixed by upstream.
  * **bug#13833:** https://lists.nongnu.org/archive/html/bug-gnu-emacs/2025-03/msg01757.html
  * **bug#53941:** https://lists.gnu.org/archive/html/bug-gnu-emacs/2024-09/msg00836.html
- The `pdd-url-backend` automatically applies the same proxy to both HTTP and HTTPS connections by default. To implement protocol-specific proxy routing (e.g., different proxies for HTTP vs HTTPS), you can use a dynamic proxy function as the Protocol-Specific example.
