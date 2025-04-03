# Integrate timers with pdd-task

The following example simulates a scenario:
- There is one URL which is very unstable, we need to retrieve its data,
- After retrieved the data, we will use it to make other tasks/requests.

The `pdd-interval-task` can deal with this easily:
- Send the request in the interval task,
- When success, return and continue,
- When fails, retry after every _N_ seconds intervally until the data is obtained

```emacs-lisp
(pdd-async
  (let* ((res (await
               (pdd-interval-task 3 t
                 ;; callback signature (&optional index return-fun)
                 ;; optional return is a function used to quit the task
                 ;; here, simulate a link hard to connect
                 (lambda (i ret)
                   (pdd "https://httpbin.org/ip"
                     :done (lambda (r) (funcall ret (alist-get 'origin r)))
                     :fail #'ignore)))))
         (data (pdd "https://httpbin.org/anything" :data res)))
    (message ">> %s, %s" res (alist-get 'form (await data)))))
```

Promise style without using `return-fn`, but using the terminate condition:
```emacs-lisp
(let (res)
  (pdd-chain (pdd-interval-task 3 (lambda () (null res))
               (lambda (i)
                 (pdd "https://httpbin.org/ip"
                   :done (lambda (r) (setq res (alist-get 'origin r)))
                   :fail #'ignore)))
    (lambda (_) (pdd "https://httpbin.org/anything" :data res))
    (lambda (r) (message ">> %s, %s" res (alist-get 'form r)))))
```

The `pdd-interval-task` can be used in many different scenarios. It can be used in any position of the task chain. For example, in the following case, it is combined with `pdd-chain` to achieve the countdown effect before request:
```emacs lisp
(pdd-chain 1
  (lambda (_)
    (message "Prepare...")
    (pdd-interval-task 1 5
      (lambda (i) (message "> Count down: %s" (- 6 i)))))

  (lambda (_)
    (message "Starting request...")
    (pdd "https://httpbin.org/ip" :done (lambda (r) (alist-get 'origin r))))

  (lambda (ip)
    (message "Prepare...")
    (pdd-interval-task 1 5
      (lambda (i) (message "> Count down: %s" (- 6 i)))
      :done (lambda () ip)))

  (lambda (ip)
    (message "Starting request...")
    (pdd "https://httpbin.org/anything" :data `((ip . ,ip))))

  (lambda (rs) (message ">>> Final result: %s" (alist-get 'form rs)))

  :fail (lambda (rr) (message "Fail: %s" rr)))
```

Besides `pdd-interval-task`, there are also `pdd-delay-task` and `pdd-timeout-task`.
