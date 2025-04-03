# Promise/A+ and Async/Await

A better Promise implement, which can make code cleaner.

[https://promisesaplus.com/](https://promisesaplus.com/)

## Example 1. sequence asynchronous

Just a little case, write code to accomplish this:
- 5 seconds later, url will be generated,
- then request this url asynchronously,
- when the request succeed, wait for 2 seconds for a new url,
- then request this new url with the data from previous response, also asynchronously,
- waiting for the response, when succeed, print the response result

This task is implemented with three different ways, all are asynchronous and will not block Emacs, please compare the code yourself.

> **Note**: the code can be run directly, test yourself.

### A. with callback syntax

```emacs-lisp
(run-with-timer 5 nil
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

### B. with promise syntax

```emacs-lisp
(let* ((pdd-default-sync :async)
       (p1 (pdd-delay-task 5 "https://httpbin.org/ip"))
       (p2 (pdd-then p1 (lambda (r) (pdd r))))
       (p3 (pdd-then p2 (lambda (r) (pdd-delay-task 2 "https://httpbin.org/anything"))))
       (p4 (pdd-then p3 (lambda (r) (pdd r :data `((hello . ,(alist-get 'origin (oref p2 value)))))))))
  (pdd-then p4
    (lambda (res) (message "> %s" (alist-get 'form res)))
    (lambda (err) (message "> something wrong: %s" err))))
```

### C. with async/await syntax

```emacs-lisp
(pdd-let* ((url1 (await (pdd-delay-task 5 "https://httpbin.org/ip")))
           (res1 (await (pdd url1)))
           (url2 (await (pdd-delay-task 2 "https://httpbin.org/anything"))))
  (pdd url2
    :data `((hello . ,(alist-get 'origin res1)))
    :done (lambda (res) (message "> %s" (alist-get 'form res)))
    :fail (lambda (err) (message "> something wrong: %s" err))))
```

## Example 2. concurrency control (first success)

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

### B. with promise syntax

```emacs-lisp
(let* ((t1 (pdd "https://httpbin.org/ip" :done (lambda (r) (alist-get 'origin r))))
       (t2 (pdd "https://httpbin.org/uuid" :done (lambda (r) (alist-get 'uuid r))))
       (t3 (pdd-delay-task 2 "timeout")))
  (pdd-then (pdd-any t1 t2 t3)
    (lambda (r) (message "> %s" r))))
```

### C. with async/await syntax

```emacs-lisp
(pdd-let* ((t1 (pdd "https://httpbin.org/ip" :done (lambda (r) (alist-get 'origin r))))
           (t2 (pdd "https://httpbin.org/uuid" :done (lambda (r) (alist-get 'uuid r))))
           (t3 (pdd-delay-task 2 "timeout"))
           (rs (await (pdd-any t1 t2 t3))))
  (message "> %s" rs))
```

## Example 3. Wrap url-retrieve with Promise

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

And then you can use it with promise and async/await syntax:
```emacs-lisp
(pdd-let*
    ((t1 (my-url-retrieve "https://httpbin.org/ip"))
     (t2 (my-url-retrieve "https://httpbin.org/user-agent")))
  (pdd-then (pdd-all t1 t2)
    (lambda (rs) (message "> results: %s" rs))))
```

Other async functions can also be wrapped in the same way.
