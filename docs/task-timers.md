# Integrate timers with pdd-task

There are three functions integrated with timer:
- `(pdd-expire time)`, reject with timeout after TIME
- `(pdd-delay time &optional value)`, resolve with VALUE after TIME
- `(pdd-interval secs count func ...)`, do some jobs intervally

Each of them return a `pdd-task` object which can chain with other tasks.

## Usage

Expire:
```emacs-lisp
(pdd-race
 (pdd-expire 1.1)
 (pdd "https://httpbin.org/ip" #'print))
```

Delay:
```emacs-lisp
(pdd-delay 3)
(pdd-delay 3 "hello")
(pdd-delay 3 (lambda () (print (float-time))))

(pdd-chain t
  (lambda () (pdd-delay 3)) ; wait 3 seconds, non-block
  (lambda () (pdd "https://httpbin.org/ip" #'print))
  (lambda () (pdd-delay 5)) ; wait 5 seconds, non-block
  (lambda () (pdd "https://httpbin.org/uuid" #'print)))
```

Interval:
```emacs-lisp
;; callback signature (&optional index return-fn)
;; optional return-fn is a function used to quit the task with result
(pdd-interval 1 5 (lambda () (print (float-time))))
(pdd-interval 1 5 (lambda (i) (message "Seq #%d" i)))
(pdd-interval 1 t (lambda (i ret) (if (> (random 10) 5) (funcall ret 666)) (message "Seq #%d" i)))

;; Task chain
(pdd-then
    (pdd-interval 1 3
      (lambda (i return)
        (if (> (random 10) 6)
            (funcall return 666)
          (message "Seq #%d" i))))
  (lambda (v i) (message "round %s, return: %s" i v))
  (lambda (err) (message "failed with error: %s" err)))

;; Same as above
(pdd-interval 1 3
  (lambda (i return)
    (if (> (random 10) 6)
        (funcall return 666)
      (message "Seq #%d" i)))
  :done (lambda (v i) (message "round %s, return: %s" i v))
  :fail (lambda (err) (message "failed with error: %s" err)))

;; Cancel the task
(setq task1 (pdd-interval ...))
(pdd-signal task1 'abort)
```

## Example 1. interval tasks

The following example simulates a scenario:
- There is one URL which is very unstable, we need to retrieve its data,
- After retrieved the data, we will use it to make other tasks/requests.

The `pdd-interval` can deal with this easily:
- Send the request in the interval task,
- When success, return and continue,
- When fails, retry after every _N_ seconds intervally until the data is obtained

```emacs-lisp
(pdd-let* ((res (await
                 (pdd-interval 3 t
                   (lambda (i ret)
                     (pdd "https://httpbin.org/ip"
                       :done (lambda (r) (funcall ret (alist-get 'origin r)))
                       :fail #'ignore)))))
           (data (pdd "https://httpbin.org/anything" :data res)))
  (message ">> %s, %s" res (alist-get 'form (await data))))
```

Promise style without using `return-fn`, but using the terminate condition:
```emacs-lisp
(let (res)
  (pdd-chain (pdd-interval 3 (lambda () (null res))
               (lambda (i)
                 (pdd "https://httpbin.org/ip"
                   :done (lambda (r) (setq res (alist-get 'origin r)))
                   :fail #'ignore)))
    (lambda (_) (pdd "https://httpbin.org/anything" :data res))
    (lambda (r) (message ">> %s, %s" res (alist-get 'form r)))))
```

The `pdd-interval` can be used in many different scenarios. It can be used in any position of the task chain. For example, in the following case, it is combined with `pdd-chain` to achieve the countdown effect before request:
```emacs lisp
(pdd-chain t
  (lambda (_)
    (message "Prepare...")
    (pdd-interval 1 5
      (lambda (i) (message "> Count down: %s" (- 6 i)))))

  (lambda (_)
    (message "Starting request...")
    (pdd "https://httpbin.org/ip" :done (lambda (r) (alist-get 'origin r))))

  (lambda (ip)
    (message "Prepare...")
    (pdd-interval 1 5
      (lambda (i) (message "> Count down: %s" (- 6 i)))
      :done (lambda () ip)))

  (lambda (ip)
    (message "Starting request...")
    (pdd "https://httpbin.org/anything" :data `((ip . ,ip))))

  (lambda (rs) (message ">>> Final result: %s" (alist-get 'form rs)))

  :fail (lambda (rr) (message "Fail: %s" rr)))
```

## Example 2. use `pdd-interval` to display progress message

With `pdd-race` + `pdd-interval` to output elisped time:
```emacs-lisp
(pdd-let* ((logs (pdd-race
                  (pdd-interval 1 t (lambda (i) (message "> time elisped %d seconds" i)))
                  (pdd-exec [git -C "/usr/local/src/emacs/" log --oneline] :as 'line)))
           (log (completing-read "Logs: " (await logs) nil t))
           (resp (pdd-race
                  (pdd-interval 1 t (lambda (i) (message "> time elisped %d seconds" i)))
                  (pdd "https://httpbin.org/anything" :data log))))
  (message ">>> %s" (await resp)))
```
