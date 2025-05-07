# Integrate make-process/shell-command with pdd-task

Interesting utility, interesting try. Non-block and easy.

Current issue:
> Some processes may wait for stdin and hang without exit. However, Emacs cannot determine which one will behave like this. This sometimes leads to not getting the results back, you need to kill the process manually. I don't know if there is a way to solve this. So, be especially careful to pay attention to processes that need to read standard input.

## Usage

The only API is `pdd-exec`:
```
(pdd-exec CMD &rest ARGS &key ENV AS FILTER INIT DONE FAIL FINE &allow-other-keys)

  CMD:     Executable name (string, list, vector or t)
           * if this is t, ARGS will be wrapped to shell command
  ARGS:    List of command arguments
           * Element can be string, symbol, list or vector
           * They will be auto flatten and stringify, so write any way you want
  ENV:     Extra process environment settings, string or list
  AS:      Transform process output specify type, function or abbrev symbol
           * If this is symbol line, split result to lines list
           * If this is a function, use its return value as result
           * Otherwise, just return the process output literally
  FILTER:  Process filter function (lambda (process string))
  INIT:    Post-creation callback (lambda (process))
           * If TYPE is pipe, and this is a string, then send it to proc pipe
           * If this is a function, just do something to proc manually with it
  DONE:    Success callback (lambda (output exit-status))
  FAIL:    Error handler (lambda (error-message))
  FINE:    Finalizer (lambda (process))

Returns a ‘pdd-task’ object that can be canceled using ‘pdd-signal’
```

Smart cmd and args syntax:
```emacs-lisp
(pdd-exec "ls" :done #'print)
(pdd-exec "ls" "-a" "-l" :done #'print)
(pdd-exec "ls" "-a -l" :done #'print)
(pdd-exec "ls" '("-a -l")) ; those in list will not be splitted
(pdd-exec 'ls '(-a -r) '-l :done #'print) ; auto stringify
(pdd-exec [ls -a -r] :done #'print) ; vector is like list
(pdd-exec "ls -a -r" :done #'print) ; shell command format string
(pdd-exec t '(tee "~/aaa.txt") :init "pipe this to tee to save") ; t: execute as shell command
```

Bind extra proc environments:
```emacs-lisp
(pdd-exec 'ls :env "X=11") ; a string for only one
(pdd-exec 'ls :env '("X=11" "Y=22")) ; a list for multiple
(pdd-exec 'ls :env '((x . 11) (y . 22))) ; alist is recommended
(pdd-exec 'ls :env '((xpath f1 f2) (x . 33))) ; paths auto join
```

Callbacks for convenience:
```emacs-lisp
(pdd-exec '(ls -l) :as 'line :done 'print)
(pdd-exec '(ls -l) :as 'my-parse-fn :done 'my-done-fn)

(pdd-exec 'ls
  :init (lambda (proc) (extra-init-job proc))
  :done (lambda (res)  (message "%s" res))
  :fail (lambda (err)  (message "EEE: %s" err))
  :fine (lambda (proc) (extra-clean-up proc)))
```

Play with task system:
```
(pdd-chain (pdd-exec [ip addr] :as 'line)
  (lambda (r) (cl-remove-if-not (lambda (e) (string-match-p "^[0-9]" e)) r))
  (lambda (r) (mapcar (lambda (e) (cadr (split-string e ":"))) r))
  (lambda (r) (pdd-interval 1 5 (lambda (i) (message "> Countdown: %d" (- 6 i))) :done r))
  (lambda (r) (message "Get interface: %s" (nth (random (length r)) r))))
```

## Example 1. interact with other tasks

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
      (pdd-exec [git log --pretty=oneline] :as 'line))

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
  (lambda (r) (pdd-exec t [tee "~/aaa.xxx"] :init r))

  ;; display file content using shell command
  (lambda (r) (pdd-exec t [cat "~/aaa.xxx"] :done #'print))

  ;; capture potential exceptions
  :fail (lambda (r) (message "EEE: %s" r)))
```

Or with async/await:
```emacs-lisp
(pdd-async
  (let* ((default-directory "~/source/emacs/")
         (logs (await (pdd-exec [git log --pretty=oneline] :as 'line)))
         (rpcs (cl-remove-if-not
                (lambda (x) (string-match-p "jsonrpc"  (cdr x)))
                (mapcar (lambda (x) (cons (substring x 0 40) (substring x 40))) logs)))
         (data (cl-subseq rpcs 0 (min (length rpcs) 10)))
         (r1 (await (pdd "https://httpbin.org/anything" :data data)))
         (_  (await (pdd-delay 3)))                     ; wait
         (r2 (await (pdd "https://httpbin.org/anything" :data (format "%s" r1)))))
    (await (pdd-exec t [tee "~/aaa.xxx"] :init r2)) ; write
    (pdd-exec t [cat "~/aaa.xxx"] :done #'print)))  ; read
```

## Example 2. inspect http headers using curl

Popup a buffer to show the request and response details quickly. This is useful sometimes:

```emacs-lisp
(pdd-exec [curl "https://httpbin.org/uuid" -v]
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

Or with async/await syntax:
```emacs-lisp
(pdd-let* ((res (pdd-exec [curl "https://httpbin.org/uuid" -v])))
  (with-current-buffer (get-buffer-create "*curl-result*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (save-excursion (insert (await res)))
      (special-mode) ; readonly, and using q to quit
      (font-lock-add-keywords ; pretty display
       nil '(("^\\* .*"  . 'font-lock-comment-face)
             ("^[<>] .*" . 'font-lock-string-face)))
      (font-lock-flush)
      (display-buffer (current-buffer)))))
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

## Example 3. a command to kill system process in Emacs

```emacs-lisp
(defun my-kill-system-process ()
  (interactive)
  (pdd-let* ((lines (pdd-exec [ps aux] :as 'line))
             (line (completing-read "Process to kill: " (cdr (await lines)) nil t))
             (strs (split-string line))
             (proc-id (cadr strs))
             (proc-name (car (last strs))))
    (when (y-or-n-p (format "Kill process: %s ?" proc-name))
      (pdd-exec `(kill -9 ,proc-id)
        :done (lambda (_) (message "DONE."))
        :fail (lambda (r) (message "[Fail] %s" r))))))
```
