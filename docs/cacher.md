# Tutorial of Cacher

Make request support cache:
- Use `:cache` or `pdd-active-cacher` to active cache support
- The value can be a `number` or a `pdd-cacher` instance and more

## Basic

```emacs-lisp
;; create cacher instance (slots: ttl/key/store)

(setq cc-1 (pdd-cacher :ttl 5))
(setq cc-2 (pdd-cacher :ttl 5 :key '(url method)))
(setq cc-3 (pdd-cacher :ttl 9 :key 'url :store my-hash-table))

;; enable cache for request with `:cache' keyword

(pdd "https://httpbin.org/ip" :cache cc-1)

;; if no `:cache' specified, `pdd-active-cacher' will used as fallback

(let ((pdd-active-cacher cc-3))
  (pdd "https://httpbin.org/ip")              ; use cache cc-3
  (pdd "https://httpbin.org/ip" :cache cc-4)  ; use cache cc-4
  (pdd "https://httpbin.org/ip" :cache nil))  ; inhibit cache

;; Some shortcuts for convenient, then a temp cacher will be used for caching

(pdd "https://httpbin.org/ip" :cache 5) ; a number or function, as the :ttl
(pdd "https://httpbin.org/ip" :cache '(5 url method)) ; ttl: 5, key: (url method)
(pdd "https://httpbin.org/ip" :cache '(5 url (store . my-hash)) ; and, store: my-hash
```

## More

A cacher instance always works behind:
```emacs-lisp
;; The `:ttl' can be a time seconds, a function or nil

(pdd-cacher :ttl 5)   ; keep live for 5 seconds
(pdd-cacher :ttl (lambda () (> (random 10) 5))) ; dynamic, use cache when return t
(pdd-cacher :ttl nil) ; never expired

;; For a request, :key can be a list mixed with slots and others

(pdd url :cache `(3 url))            ; use (oref request url) as real key cause url is slot of request
(pdd url :cache `(3 url method))     ; key: (list (oref request url) (oref request method))
(pdd url :cache `(3 my-delete url))  ; key: (list 'my-delete (oref request url))
(pdd url :cache `(3 url (data . x))) ; key: (list (oref request url) (alist-get 'x (oref request data)))
(pdd url :cache `(3 url (headers . user-agent) (data . (x . y)))) ; deep alist
(pdd url :cache `(3 ,(lambda (v) ..))) ; use the result of function as the cache key
(pdd url :cache 3) ; by default, use the slots `(url method headers data) to make cache key

;; Use :store to specify where to save the caches

(pdd-cacher :store (make-hash-table :test #'equal))
(pdd-cacher :store 'a-hash-table-symbol)
(pdd-cacher)  ; by default, store into hash table of `pdd--shared-request-storage'

;; The :store can be a directory, that is, cache to disk as a local file
;; Also can extend `pdd-cacher' to make it support database and so on

(pdd-cacher :store "~/vvv/aaa/") ; cache to files under this directory

;; Different cachers can share one same storage

(defvar shared-storage-1 (make-hash-table :test #'equal))
(defvar cc-5 (pdd-cacher :ttl 10 :store 'shared-storage-1))
(defvar cc-6 (pdd-cacher :ttl 60 :store 'shared-storage-1))

(pdd "https://httpbin.org/ip" :cache cc-5)
(pdd "https://httpbin.org/ip" :cache cc-6)

;; Bind `pdd-cache-ttl/key/store' dynamically to change the new created pdd-cacher

(let ((pdd-cache-ttl 120)
      (pdd-cache-store my-hash-table))
  (pdd url :cache t)    ; use a cacher with ttl 120 and storage my-hash-table
  (pdd url :cache 666)  ; use a cacher with ttl 666 and storage my-hash-table
  (pdd url :cache '(5 (data . path) (store . "~/vvv/aaa"))) ; override all
  (pdd url :cache nil)) ; inhibit cache
```
