# Tutorial of Cacher

Make request support cache:
- Use `:cache` or `pdd-active-cacher` to active cache support
- The value can be a `number` or a `pdd-cacher` instance and more

## Basic

```emacs-lisp
;; create cacher instance

(setq cc-1 (pdd-cacher :ttl 5))
(setq cc-2 (pdd-cacher :ttl 5 :keys '(url method)))
(setq cc-3 (pdd-cacher :ttl 9 :keys 'url :storage my-hash-table))
(setq cc-4 (pdd-cacher :ttl (lambda (v) (random 40))))

;; enable cache with `:cache' keyword

(pdd "https://httpbin.org/ip" :cache cc-1)

;; if no `:cache' specified, `pdd-active-cacher' will used as fallback

(let ((pdd-active-cacher cc-3))
  (pdd "https://httpbin.org/ip")              ; use cache cc-3
  (pdd "https://httpbin.org/ip" :cache cc-4)  ; use cache cc-4
  (pdd "https://httpbin.org/ip" :cache nil))  ; disable cache

;; Some shortcuts for convenient, then a temp cacher will be used for caching

(pdd "https://httpbin.org/ip" :cache 5) ; a number or function, as the :ttl
(pdd "https://httpbin.org/ip" :cache '(5 url method)) ; ttl: 5, keys: (url method)
(let ((pdd-shared-cache-storage my-hash-table)) (pdd url :cache 5)) ; storage
```

## More

A cacher instance always works behind:
```emacs-lisp
;; The `:ttl' can be a function, a number, nil or t

(pdd-cacher :ttl nil) ; no cache
(pdd-cacher :ttl t)   ; never expired
(pdd-cacher :ttl 5)   ; keep live for 5 seconds
(pdd-cacher :ttl (lambda (result) (random 10))) ; dynamic

;; For a request, :keys can be a list mixed with slots and others

(pdd-cacher :keys 'url)              ; use (oref request url) as real key cause url is slot of request
(pdd-cacher :keys '(url method))     ; key: (list (oref request url) (oref request method))
(pdd-cacher :keys '(my-delete url))  ; key: (list 'my-delete (oref request url))
(pdd-cacher :keys '(url (data . x))) ; keys: (list (oref request url) (alist-get 'x (oref request data)))
(pdd-cacher :keys '(url (headers . user-agent) (data . (x . y)))) ; deep alist
(pdd-cacher :keys (lambda (v) ..))   ; use the result of function as the cache key
(pdd-cacher)  ; by default, use the slots `(url method headers data) to make cache key

;; Use :storage to specify where to save the caches

(pdd-cacher :storage (make-hash-table :test #'equal))
(pdd-cacher :storage 'a-hash-table-symbol)
(pdd-cacher)  ; by default, store into hash table of `pdd--shared-request-storage'

;; Different cachers can share one same storage

(defvar shared-storage-1 (make-hash-table :test #'equal))
(defvar cc-5 (pdd-cacher :ttl 10 :storage 'shared-storage-1))
(defvar cc-6 (pdd-cacher :ttl 60 :storage 'shared-storage-1))

(pdd "https://httpbin.org/ip" :cache cc-5)
(pdd "https://httpbin.org/ip" :cache cc-6)
```
