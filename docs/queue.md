# Tutorial of Queue

There is one light and smart queue implement.

## Usage

The use of queue is non-intrusive. Just create a queue object and enable it.

Create queue (indeed a semaphore object):
```emacs-lisp
;; there are two mechanisms: concurrency control and request throttling

;; concurrency control: how many connections are allowed at same time
(setq queue1 (pdd-queue))           ; default limit to 10 concurrency
(setq queue2 (pdd-queue :limit 6))  ; specify concurrency with :limit
(setq queue3 (pdd-queue :limit 1))  ; limit to 1, means, request one by one

;; request throttling: limit request rates during one second (QPS)
(setq queue4 (pdd-queue :rate 2))   ; at most 2 requests per second
(setq queue5 (pdd-queue :rate 0.2)) ; start a request every 5 seconds

;; or mix two mechanisms together
(setq queue6 (pdd-queue :limit 4 :rate 9)) ; concurrency 4 + QPS 9

;; also you can dynamically dispatch queues with a function queue
(setq queue7
      (lambda (request)
        (cond ((string-match-p "/image" (oref request url)) queue1)
              ((> (random 10) 5) queue2))))
```

Then use the created queue object with `:queue`:
```emacs-lisp
;; specify a queue, and the request will be auto managed by it
(pdd "https://httpbin.org/ip" :done #'print :queue queue1)

;; notice, only asynchronous requests can be queued, otherwise :queue will be ignored
(let ((pdd-sync nil))
  (dotimes (i 20) (pdd "https://httpbin.org/ip" :queue queue2)))

;; dispatch different requests to different queues
(let ((pdd-sync nil))
  (pdd "https://httpbin.org/ip" :queue queue3)
  (pdd "https://httpbin.org/ip" :queue queue4)
  (pdd "https://httpbin.org/ip")
  (dotimes (i 20) (pdd "https://httpbin.org/ip" :queue queue3))
  (dotimes (i 20) (pdd "https://httpbin.org/ip" :queue queue7)))
```

Use `pdd-active-queue` to make things easier:
```emacs-lisp
;; set global value for all `pdd's without :queue specified
(setq pdd-active-queue (pdd-queue :limit 3))
(pdd "https://httpbin.org/ip" :done #'print) ; this will be auto managed by default queue

;; but global value is not recommended, dynamic binding is preferred!
(let ((pdd-active-queue (pdd-queue :limit 1)))
  (dotimes (i 20) (pdd "https://httpbin.org/ip" :queue queue1)) ; these use queue1
  (dotimes (i 20) (pdd "https://httpbin.org/ip"))) ; these use the default queue (request one by one)

;; there is a `:fine' callback, will be triggered every time when queue is empty
(let ((pdd-active-queue (pdd-queue :limit 1 :fine (lambda () (message "Done.")))))
  (dotimes (i 20) (pdd "https://httpbin.org/ip")))
```

The `limit/rate` can be dynamical changed:
```emacs-lisp
(setq queue1 (pdd-queue :rate 0.3)) ; initial rate

(dotimes (i 20)
  (pdd "https://httpbin.org/ip"
    (lambda ()
      (pcase i ; change in runtime
        (3 (oset queue1 rate 2))
        (7 (oset queue1 rate 5)))
      (message "> %d. %s" i (format-time-string "%T")))
    :queue queue1))
```

## Example. Finish these requests with 20 seconds

```emacs-lisp
(let* ((begin (current-time))
       (pdd-active-queue (pdd-queue
                           :rate 2.7 ; 50 / 20 = 2.5
                           :fine (lambda ()
                                   (message "Elapsed %d seconds"
                                            (float-time (time-since begin)))))))
  (dotimes (i 50)
    (pdd "https://httpbin.org/ip"
      (lambda (r) (message "> %d. %s" i (alist-get 'origin r))))))
```

## Example. Who is faster, url.el or plz.el?

A simple benchmark function:

```emacs-lisp
(defun who-is-faster-backend (backend concurrent-number total &optional url)
  (let* ((pdd-sync nil) ; make sure it's async request
         (beg (current-time))   ; record start time
         (stat-time (lambda () (message "Time used: %.1f" (time-to-seconds (time-since beg)))))
         (pdd-active-queue (pdd-queue :limit concurrent-number :fine stat-time))
         (pdd-backend (pcase backend ('url (pdd-url-backend)) ('plz (pdd-curl-backend)))))
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
