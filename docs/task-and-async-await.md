# Task and Async/Await

The library provides a robust [Promise/A+](https://promisesaplus.com/) implementation through the `pdd-task`, offering full asynchronous control flow capabilities.

> Although there are already implementations of `promise.el` and `emacs-aio` in emacs, I feel that they do not meet my expectations for promises and async/await. They are too much of a JavaScript/Python style, and not too easy to use (just my personal opinion).
>
> My implementation is designed to work perfectly with `pdd` requests, but in fact, it can be completely standalone. This task system is universal, not only `pdd` can use it, other asynchronous scenarios can also use it.

## `pdd-task`: A Promise/A+ Implementation for Emacs Lisp

A `pdd-task` is an object representing the a running asynchronous process. It helps manage asynchronous process's lifecycle. It will hold the most important informations of the asynchronous process, including `state`, `data` and `error`, and act as the agent of the process.

There are 3 different task states to represent the different stages of asynchronous process:
* **`pending`**: The initial state when the asynchronous process starts. The task holds no result or error yet (`pending nil`).
* **`fulfilled`**: The state upon successful completion of the process. The task holds the resulting `data` (`fulfilled data`).
* **`rejected`**: The state if the process fails. The task holds the `reason` for the failure (an error object) (`rejected reason`).

One task can only transition from `pending` to either `fulfilled` or `rejected` once.

The lifecycle of a `pdd-task` mirrors the asynchronous process it represents, and the slots of `pdd-task` object will be managed by the asynchronous process. For an asynchronous process, what to do is:
1. **Creation**: Create a task using `pdd-task` (function) or `pdd-with-new-task` (macro) when the asynchronous process begins. The task starts with the `pending` state.
2. **Settling**: Inside the asynchronous process's callback, call the appropriate function to "settle" the task:
   * `pdd-resolve task data`: Transitions the task to `fulfilled` and stores the `data`.
   * `pdd-reject task reason`: Transitions the task to `rejected` and stores the `reason`.
3. **Return**: The function initiating the asynchronous process should return the created `pdd-task` instance immediately.

Once you have a `pdd-task` instance, forget the asynchronous process itself, just manage the asynchronous flow by operating on this task:
*  Register callbacks to handle the task's settlement with **`(pdd-then task on-fulfilled on-rejected)`**:
   * `on-fulfilled`: A function auto executed when task becomes `fulfilled`, with `data` as argument.
   * `on-rejected`: A function auto executed when task becomes `rejected`, with fail `reason` as argument.
*  After register, `pdd-then` returns a *new* `pdd-task`. You can call `pdd-then` again and again on new task, so a **task chain** is created. Values (on success) or errors (on failure) propagate through this chain.
*  If an `on-fulfilled` callback returns another `pdd-task`, the chain automatically waits for *that* inner task to settle, and its result (or error) is passed down the main chain. This **flattens nested callbacks**. This is the biggest benefit of using tasks.

As you can see, the core functions are `pdd-task`, `pdd-resolve`, `pdd-reject` and `pdd-then`, they almost compose everything. Also there are some auxiliary helpers or utilities, they are necessary for different scenarios:
*  `pdd-signal`: Sends a signal to a task, usually used to cancel a task as `(pdd-signal task 'cancel)`.
*  `pdd-chain`: A convenience function built on `pdd-then` for simplifying sequential task chains.
*  `pdd-all`, `pdd-any`, `pdd-race`: Manage multiple concurrent tasks.
*  `pdd-delay`, `pdd-timeout`, `pdd-interval`: Utilities integrating Emacs timers with tasks.
*  `pdd-async/await*`: Provides syntax sugar for a more synchronous-looking style when working with tasks, just like what ts/c# done.

Explain with some codes:
```emacs-lisp
;; 1. Task lifecycle tied to an async operation (e.g., url-retrieve)
(let ((task (pdd-task))) ; Create task: (pending nil)
  (url-retrieve url
    (lambda (status) ; url-retrieve's callback
      (if (url-http-successful-p status)
          ;; Success: Settle task as (fulfilled buffer-content)
          (pdd-resolve task (buffer-string))
        ;; Failure: Settle task as (rejected status/error)
        (pdd-reject task status)))
  task) ; Return the task immediately which is still pending

;; 2. Using `pdd-then' to register callbacks and make task chain
(pdd-then
    (pdd-then task
      ;; on-fulfilled: auto called if task is resolved
      (lambda (buffer-string)
        (message "Success! Data length: %d" (length buffer-string))
        (do-something-with buffer-string)) ; result will be propagate to the chain (if exists)
      ;; on-rejected: auto called if task is rejected
      (lambda (error-reason)
        (message "Failed! Reason: %S" error-reason)
        (handle-the-error error-reason))) ; the first descendant in chain
  on-fulfilled on-rejected) ; the next descendant in chain

;; Using auxiliary functions like `pdd-chain' can make things easier
(pdd-chain (pdd url1)  ; Start with url1
  (lambda (result1)    ; When url1 succeeds, fetch url2
    (message "Got url1: %s" result1)
    (pdd url2))
  (lambda (result2)    ; When url2 succeeds, fetch url3
    (message "Got url2: %s" result2)
    (pdd url3))
  (lambda (result3)    ; When url3 succeeds...
    (message "Got url3: %s" result3)))

;; Cancelling a task
(let ((long-task (pdd "long-running-request")))
  ;; ... maybe later
  (pdd-signal long-task 'cancel)) ; Send a 'cancel signal
```

Next, I will provide some usage examples. Most of these examples can be run directly, and you can try them yourself.

## Example 1. sequence asynchronous

Just a little case, write code to accomplish this:
- 5 seconds later, url will be generated,
- then request this url asynchronously,
- when the request succeed, wait for 2 seconds for a new url,
- then request this new url with the data from previous response, also asynchronously,
- waiting for the response, when succeed, print the response result

This task is implemented with three different ways, all are asynchronous and will not block Emacs, please compare the code yourself.

### A. with callback syntax

```emacs-lisp
(run-with-timer 3 nil
  (lambda ()
    (let ((url "https://httpbin.org/ip") r2)
      (pdd url
        :sync nil
        :done (lambda (r)
                (setq r2 r)
                (run-with-timer 2 nil
                  (lambda ()
                    (let ((url "https://httpbin.org/anything"))
                      (pdd url
                        :sync nil
                        :data `((hello . ,(alist-get 'origin r2)))
                        :done (lambda (res)
                                (message "> %s" (alist-get 'form res)))
                        :fail (lambda (err)
                                (message "> something wrong: %s" err)))))))))))
```

### B. with task syntax

```emacs-lisp
(let* ((pdd-default-sync nil)
       (t1 (pdd-delay 3 "https://httpbin.org/ip"))
       (t2 (pdd-then t1 (lambda (r) (pdd r))))
       (t3 (pdd-then t2 (lambda (r) (pdd-delay 2 "https://httpbin.org/anything"))))
       (t4 (pdd-then t3 (lambda (r) (pdd r :data `((hello . ,(alist-get 'origin (car (aref t2 2))))))))))
  (pdd-then t4
    (lambda (res) (message "> %s" (alist-get 'form res)))
    (lambda (err) (message "> something wrong: %s" err))))
```

With the help of auxiliary function `pdd-chain`:
```emacs-lisp
(let (r2)
  (pdd-chain (pdd-delay 3 "https://httpbin.org/ip")
    (lambda (r) (pdd r))
    (lambda (r) (setq r2 r) (pdd-delay 2 "https://httpbin.org/anything"))
    (lambda (r) (pdd r :data `((hello . ,(cdar r2)))))
    (lambda (r) (message "> %s" (alist-get 'form r)))
    :fail
    (lambda (e) (message "> something wrong: %s" e))))
```

### C. with async/await syntax

```emacs-lisp
(pdd-async
  (let* ((url1 (await (pdd-delay 3 "https://httpbin.org/ip")))
         (res1 (await (pdd url1)))
         (url2 (await (pdd-delay 2 "https://httpbin.org/anything"))))
    (pdd url2
      :data `((hello . ,(alist-get 'origin res1)))
      :done (lambda (res) (message "> %s" (alist-get 'form res)))
      :fail (lambda (err) (message "> something wrong: %s" err)))))
```

## Example 2. Wrap url-retrieve with Promise

First, wrap `url-retrieve` that make it return a `pdd-task` instance:
```emacs-lisp
(defun my-url-retrieve (url)
  (pdd-with-new-task
   (url-retrieve url
     (lambda (status)
       (unwind-protect
           (if-let* ((err (plist-get status :error)))
               (pdd-reject it err) ; error case
             (pdd-resolve it ; success case
               (buffer-substring url-http-end-of-headers (point-max))))
         (kill-buffer (current-buffer)))))))
```

And then you can use it with task and async/await syntax:
```emacs-lisp
(pdd-async
  (let* ((t1 (my-url-retrieve "https://httpbin.org/ip"))
         (t2 (my-url-retrieve "https://httpbin.org/user-agent")))
    (message "> results: %s" (await t1 t2))))
```

Other async functions can also be wrapped in the same way.

## Example 3. concurrency control (first success)

Write code to accomplish this without block Emacs:
- request url1 and url2 at the same time
- in 2 seconds, return response result of the first successful request
- after 2 seconds, if no request success, display "timeout"

### A. with normal syntax

```emacs-lisp
(let (r1 r2 r3)
  (cl-flet ((try-final ()
              (when (= 1 (length (cl-remove nil (list r1 r2 r3))))
                (message "> %s" (or r1 r2 r3)))))
    (pdd "https://httpbin.org/ip"
      :done (lambda (r)
              (setq r1 (alist-get 'origin r))
              (try-final)))
    (pdd "https://httpbin.org/uuid"
      :done (lambda (r)
              (setq r2 (alist-get 'uuid r))
              (try-final)))
    (run-with-timer 2 nil
                    (lambda ()
                      (setq r3 "timeout")
                      (try-final)))))
```

### B. with task syntax

```emacs-lisp
(let* ((t1 (pdd "https://httpbin.org/ip" :done (lambda (r) (alist-get 'origin r))))
       (t2 (pdd "https://httpbin.org/uuid" :done (lambda (r) (alist-get 'uuid r))))
       (t3 (pdd-delay 2 "timeout")))
  (pdd-then (pdd-any t1 t2 t3)
    (lambda (r) (message "> %s" r))))
```

### C. with async/await syntax

```emacs-lisp
(pdd-async
  (let* ((t1 (pdd "https://httpbin.org/ip" :done (lambda (r) (alist-get 'origin r))))
         (t2 (pdd "https://httpbin.org/uuid" :done (lambda (r) (alist-get 'uuid r))))
         (t3 (pdd-delay 2 "timeout")))
    (message "> %s" (await (pdd-any t1 t2 t3)))))
```

## Example 4. concurrency control (all success)

Fetch data from github. With `pdd-all` to retrieve data from several requests at the same time and continue with all of them successfully responsed.

### A. with task syntax

```emacs-lisp
(let ((tags '(followers_url repos_url subscriptions_url organizations_url)))

  (pdd-chain "https://api.github.com/users/lorniu"
    (lambda (url) (pdd url)) ; request now

    (lambda (json) ; filter
      (mapcar (lambda (x) (alist-get x json)) tags))

    (lambda (user-data) ; request all the urls for data
      (apply #'pdd-all (mapcar (lambda (url) (pdd url)) user-data)))

    (lambda (result-lst) ; collection
      (cl-loop for tag in tags for data in result-lst
               collect (cons tag data)))

    (lambda (acc-list) ; extract and display
      (message "> %s" acc-list))

    :fail
    (lambda (err) ; catch error in the chain
      (message "EEE: %s" err))))
```

### B. with async/await async

```emacs-lisp
(pdd-async
  (let* ((tags '(followers_url repos_url subscriptions_url organizations_url))
         (user-data (pdd "https://api.github.com/users/lorniu"
                      :done (lambda (json) (mapcar (lambda (x) (alist-get x json)) tags))))
         (result-lst (apply #'pdd-all (mapcar (lambda (url) (pdd url)) (await user-data))))
         (acc-lst (cl-loop for tag in tags for data in (await result-lst)
                           collect (cons tag data))))
    (message "> %s" acc-lst)))
```

## Example 5. the more complex the logic, the more concise the code appears

```emacs-lisp
(pdd-async
  (let* ((r1 (pdd "https://httpbin.org/ip"))
         (r2 (pdd "https://httpbin.org/user-agent"))
         (r3 (await r1 r2))
         (r4 (await (pdd-delay 2 "https://httpbin.org/uuid")))
         (r5 (cons 1 (await (pdd r4))))
         (r6 (pdd "https://httpbin.org/user-agent")))
    (message "> %s %s %s" r3 r5 (await r6))))
```

## More you also should know

- [Integrate timers with pdd-task](task-timers.md)
- [Integrate make-process with pdd-task](task-process.md)
