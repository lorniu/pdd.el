# Tutorial of Queue

There is one light and smart queue implement.

## Basic usage

The use of queue is non-intrusive. Just specify a queue object using `:queue` to enable queuing:
```emacs-lisp
;; create queue (indeed a semaphore object)
(setq queue2 (pdd-queue :limit 2)) ; specify concurrent with :limit
(setq queue1 (pdd-queue))          ; default limit to 6

;; use different queues for different async requests
(let ((pdd-default-sync nil))
  (dotimes (i 20) (pdd "https://httpbin.org/ip" :queue queue1))
  (dotimes (i 20) (pdd "https://httpbin.org/ip" :queue queue2)))

;; request will be auto added to the specified queue
;; notice: only those asynchronous requests will be added
(let ((pdd-default-sync nil))
  (pdd "https://httpbin.org/ip" :queue queue1)
  (pdd "https://httpbin.org/ip" :queue queue2)
  (pdd "https://httpbin.org/ip")
  (pdd "https://httpbin.org/ip" :queue queue2))
```

Use `pdd-default-queue` to make things easier:
```emacs-lisp
;; set global value for all `pdd' without specify :queue
(setq pdd-default-queue (pdd-queue :limit 3))
(pdd "https://httpbin.org/ip" :done #'print) ; this will auto be managed by default queue

;; But global value is not recommended, dynamic binding is preferred!
(let ((pdd-default-queue (pdd-queue :limit 1)))
  (dotimes (i 20) (pdd "https://httpbin.org/ip" :queue queue1))
  (dotimes (i 20) (pdd "https://httpbin.org/ip"))) ; these will use the default queue (request one by one)

;; There is a `:fine' callback, will be triggered every time when queue is empty
(let ((pdd-default-queue (pdd-queue :limit 1 :fine (lambda () (message "Done.")))))
  (dotimes (i 20) (pdd "https://httpbin.org/ip")))
```

## Example. Who is faster, url.el or plz.el?

A simple benchmark function:

```emacs-lisp
(defun who-is-faster-backend (backend concurrent-number total &optional url)
  (let* ((pdd-default-sync nil) ; make sure it's async request
         (beg (current-time))   ; record start time
         (stat-time (lambda () (message "Time used: %.1f" (time-to-seconds (time-since beg)))))
         (pdd-default-queue (pdd-queue :limit concurrent-number :fine stat-time))
         (pdd-default-backend (pcase backend ('url (pdd-url-backend)) ('plz (pdd-curl-backend)))))
    (dotimes (i total)
      (pdd (or url "https://httpbin.org/ip")
        :done (lambda () (message "%s: yes" i))
        :fail (lambda () (message "%s: no" i))))))

;; order of the test results:  Linux | Windows 11 | macOS

;; url vs plz: with 1 concurrent, total 20 requests.
(who-is-faster-backend 'url 1 20)    ; 8.2s  | 5.6s  | 8.3s
(who-is-faster-backend 'plz 1 20)    ; 32.5s | 27.6s | 24.5s

;; url vs plz: with 2 concurrent, total 40 requests.
(who-is-faster-backend 'url 2 40)    ; 7.3s  | 9.1s  | 7.3s
(who-is-faster-backend 'plz 2 40)    ; 30.3s | 26.5s | 22.6s

;; url vs plz: with 5 concurrent, total 100 requests.
(who-is-faster-backend 'url 5 100)   ; 8.0s  | 8.2s  | 7.8s
(who-is-faster-backend 'plz 5 100)   ; 30.6s | 27.3s | 21.9s

;; url vs plz: with 10 concurrent, total 1000 requests.
(who-is-faster-backend 'url 10 1000) ; 39.7s  | 38.9s  | 39.2s
(who-is-faster-backend 'plz 10 1000) ; 156.2s | 134.1s | 106.2s
```

I used to think that `plz` was much faster than `url.el`. But now after this testing, I found out that I am completely wrong.
In various situations, whether it's single concurrency or multiple concurrency, `plz` is at least 3 times as slow as `url.el`.
It seems that frequent process creation is not only a resource consumption issue, but also severely impacts speed.

Incredibly, **`url.el` is indeed more high-performance**, although not very stable.
