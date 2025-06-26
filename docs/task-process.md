# Integrate make-process/shell-command with pdd-task

Interesting utility, interesting try.

Current issue:
> Some processes may wait for stdin and hang without exit. However, Emacs cannot determine which one will behave like this. This sometimes leads to not getting the results back, you need to kill the process manually. I don't know if there is a way to solve this. So, be especially careful to pay attention to processes that need to read standard input.

## Usage

The only API is `pdd-exec`:
```
(pdd-exec CMD &rest ARGS &key ENV AS PEEK INIT DONE FAIL FINE PIPE CACHE SYNC &allow-other-keys)

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
  INIT:    Post-creation callback (lambda (process))
           * If type is pipe, and this is a string, then send it to proc pipe
           * If this is a function, just do something to proc manually with it
  PEEK:    Function to call in filter (lambda (string process))
  DONE:    Success callback (lambda (output exit-status))
  FAIL:    Error handler (lambda (error-message))
  FINE:    Finalizer (lambda (process))
  PIPE:    If t, use pipe connection type for process explicitly
  CACHE:   Enable cache support if this is not nil
           * If this is a cacher instance, use configs in it
           * If this is a number or function, use this as ttl
           * If this is a cons cell, should be (ttl &optional key store)
  SYNC:    If t, execute synchronously. In this case `:peek' is ignored

SYNC and FAIL can be dynamically bound with `pdd-sync' and `pdd-fail'.

Return a ‘pdd-task’ object that can be canceled using ‘pdd-signal’ by default,
or return the result directly when SYNC is t.
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
(pdd-exec [ps aux] :sync t :pipe t :cache 5) ; other keywords
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

## Example 3. refactor example 2

It looks like using a separate buffer to display content is quite common, so separate out:
```emacs-lisp
(defmacro pdd:with-current-view-buffer (buffer &rest keywords-and-body)
  "Similar as `with-current-buffer' but popup the buffer at last in view mode.
Usage: (pdd:with-current-view-buffer :focus/:append/:wc/:fontify/:post... (insert ...))"
  (declare (indent 1))
  (let (append focus wc fontify post body)
    (setq body
          (cl-loop for lst on keywords-and-body by #'cddr
                   if (and (keywordp (car lst)) (cdr lst))
                   do (pcase (car lst)
                        (:append (setq append (cadr lst)))
                        (:focus (setq focus (cadr lst)))
                        (:wc (setq wc (cadr lst)))
                        (:fontify (setq fontify (cadr lst)))
                        (:post (setq post (cadr lst))))
                   else return lst))
    `(with-current-buffer ,(if (stringp buffer) `(get-buffer-create ,buffer) buffer)
       (let ((inhibit-read-only t))
         (goto-char (point-max))
         ,(if append
              `(insert (if (> (point) (point-min)) "\n" ""))
            `(erase-buffer))
         (save-excursion ,@body)
         ,(if (symbolp post) `(eval ,post) post)
         (special-mode)
         ,@(when fontify
             `((font-lock-add-keywords nil ,fontify)
               (font-lock-flush)))
         (set-buffer-modified-p nil)
         (,(if focus 'pop-to-buffer 'display-buffer) (current-buffer) ,wc)))))

(cl-defun pdd:buffer-view (message &key buffer (focus t) (wc '((display-buffer-below-selected))) fontify post)
  "Popup a buffer to display message."
  (let ((buf (or buffer (get-buffer-create (format "*view-%d*" (float-time))))))
    (pdd:with-current-view-buffer buf
      :fontify fontify :post post :wc wc
      (insert (if (stringp message) message (format "%s" message))))
    (if focus (pop-to-buffer buf))))

;; (pdd:buffer-view "hello world")
;; (pdd:buffer-view "hello world" :buffer (get-buffer-create "abc") :wc '((display-buffer-at-bottom)))
```

Then, inspecting http headers using curl can be simplified to:
```emacs-lisp
(pdd-exec [curl https://httpbin.org/uuid -v] :done #'pdd:buffer-view)

(pdd-exec [curl https://httpbin.org/uuid -v]
  :done (lambda (r)
          (pdd:buffer-view r
            :fontify '(("^\\* .*" . font-lock-comment-face)
                       ("^[<>] .*" . font-lock-string-face)))))
```

Many shell commands can be used in conjunction with `pdd:buffer-view`, it is quite convenient:
```emacs-lisp
(pdd-exec [lsof] :done 'pdd:buffer-view)
(pdd-exec [ip addr] :done 'pdd:buffer-view)
(pdd-exec [brew list] :done 'pdd:buffer-view)
(pdd-exec t [awk "/load/{print}" ~/.emacs.d/init.el] :done 'pdd:buffer-view)
```

Furthermore, perhaps such a command would be quite practical (`M-x pdd:execute-and-show`):
```emacs-lisp
(defun pdd:exec-and-show (&optional cmd)
  (interactive (list (read-string "Command to execute: ")))
  (pdd-exec t (list cmd) :done 'pdd:buffer-view))
```

## Example 4. a command to kill system process in Emacs

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
