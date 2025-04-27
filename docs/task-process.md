# Integrate make-process/shell-command with pdd-task

Interesting utility, interesting try. Non-block and easy.

Current issue:
> Some processes may wait for stdin and hang without exit. However, Emacs cannot determine which one will behave like this. This sometimes leads to not getting the results back, you need to kill the process manually. I don't know if there is a way to solve this. So, be especially careful to pay attention to processes that need to read standard input.

## Example 1. process play with other tasks

Case just for demo:
- get the git log,
- filter and format,
- send to internet,
- other stuff,
- save to file

```emacs-lisp
(pdd-chain
    ;; git log of the repository, parse to list
    (let ((default-directory "~/source/emacs/"))
      (pdd-process '(git log --pretty=oneline) :as 'line))

  ;; format and filter
  (lambda (r) (mapcar (lambda (x) (cons (substring x 0 40) (substring x 40))) r))
  (lambda (r) (cl-remove-if-not (lambda (x) (string-match-p "jsonrpc"  (cdr x))) r))
  (lambda (r) (cl-subseq r 0 (min (length r) 10)))

  ;; request with the results
  (lambda (r) (pdd "https://httpbin.org/anything" :data r))

  ;; maybe some other tasks, take delay for example
  (lambda (r) (pdd-delay 3 r))

  ;; maybe some other tasks, take another request for example
  (lambda (r) (pdd "https://httpbin.org/anything" :data (format "%s" r)))

  ;; write to file using command. t says: wrap the command with shell
  (lambda (r) (pdd-process t `(tee "~/aaa.xxx") :init r))

  ;; display file content using shell command
  (lambda (r) (pdd-process t `(cat "~/aaa.xxx") :done #'print))

  ;; capture potential exceptions
  :fail (lambda (r) (message "EEE: %s" r)))
```

Or with async/await:
```emacs-lisp
(pdd-async
  (let* ((default-directory "~/source/emacs/")
         (logs (await (pdd-process '(git log --pretty=oneline) :as 'line)))
         (rpcs (cl-remove-if-not
                (lambda (x) (string-match-p "jsonrpc"  (cdr x)))
                (mapcar (lambda (x) (cons (substring x 0 40) (substring x 40))) logs)))
         (data (cl-subseq rpcs 0 (min (length rpcs) 10)))
         (r1 (await (pdd "https://httpbin.org/anything" :data data)))
         (_  (await (pdd-delay 3)))                     ; wait
         (r2 (await (pdd "https://httpbin.org/anything" :data (format "%s" r1)))))
    (await (pdd-process t `(tee "~/aaa.xxx") :init r2)) ; write
    (pdd-process t `(cat "~/aaa.xxx") :done #'print)))  ; read
```

## Example 2. inspect http headers using curl

Popup a buffer to show the request and response details quickly. This is useful sometimes:

```emacs-lisp
(pdd-process '(curl "https://httpbin.org/uuid" -v)
  :done (lambda (r)
          (with-current-buffer (get-buffer-create "*curl-result*")
            (let ((inhibit-read-only t))
              (erase-buffer)
              (save-excursion (insert r))
              (special-mode) ; readonly, and using q to quit
              (font-lock-add-keywords ; pretty display
               nil '(("^\\* .*"  . 'font-lock-comment-face)
                     ("^[<>] .*" . 'font-lock-string-face)))
              (font-lock-flush)
              (display-buffer (current-buffer))))))
```

Or with async/await:
```emacs-lisp
(pdd-async
  (let* ((url "https://httpbin.org/uuid")
         (res (await (pdd-process `(curl ,url -v)))))
    (with-current-buffer (get-buffer-create "*curl-result*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (save-excursion (insert res))
        (special-mode) ; readonly, and using q to quit
        (font-lock-add-keywords ; pretty display
         nil '(("^\\* .*"  . 'font-lock-comment-face)
               ("^[<>] .*" . 'font-lock-string-face)))
        (font-lock-flush)
        (display-buffer (current-buffer))))))
```

Something like this will be displayed:
```
> GET /uuid HTTP/2
> Host: httpbin.org
> User-Agent: curl/8.13.0
> Accept: */*
>
* Request completely sent off
< HTTP/2 200
< date: Sat, 12 Apr 2025 17:31:37 GMT
< content-type: application/json
< content-length: 53
< server: gunicorn/19.9.0
< access-control-allow-origin: *
< access-control-allow-credentials: true
<
{
  "uuid": "b9e3c2ee-55c0-4809-8976-2da6c2f2710a"
}
* Connection #0 to host httpbin.org left intact
```
