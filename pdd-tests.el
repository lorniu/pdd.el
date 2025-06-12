;;; pdd-tests.el --- Tests -*- lexical-binding: t -*-

;; Copyright (C) 2025 lorniu <lorniu@gmail.com>

;; Author: lorniu <lorniu@gmail.com>
;; URL: https://github.com/lorniu/pdd.el
;; License: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Unit Tests
;;
;;   M-x eval-buffer
;;   M-x ert
;;

;;; Code:

(require 'ert)
(require 'pdd)
(require 'plz)

(defconst pdd-test-backends '(url curl))

(defvar pdd-test-host "https://httpbin.org")

;;(setq pdd-debug nil)
;;(setq pdd-sync nil)
;;(setq pdd-sync t)
;;(setq pdd-base-url pdd-test-host)
;;(setq pdd-backend (pdd-url-backend))
;;(setq pdd-backend (pdd-curl-backend))

(defun pdd-block-and-wait-proc (proc)
  (cl-loop while (ignore-errors (buffer-live-p (process-buffer proc)))
           do (sleep-for 0.2)))

(defmacro pdd-test-req (backend &rest args)
  "Wrap `pdd' to ease tests."
  (declare (indent 1))
  `(let ((pdd-base-url ,pdd-test-host)
         (pdd-backend (,(intern (format "pdd-%s-backend" backend)))))
     (pdd ,@args)))

(cl-defmacro pdd-deftests (name (&rest forbidens) &rest body)
  "Build test functions, cover all the cases by composing url/curl and sync/aync."
  (declare (indent 2))
  (cl-labels
      ((walk-inject (expr backend sync)
         (cond
          ((and (consp expr) (eq (car expr) 'pdd))
           `(let ((proc (pdd-test-req ,backend ,@(cdr expr))))
              ,(if (eq :async sync) `(pdd-block-and-wait-proc proc))))
          ((consp expr)
           (cons (walk-inject (car expr) backend sync)
                 (walk-inject (cdr expr) backend sync)))
          (t expr)))
       (deftest (backend sync)
         (let* ((sync (or sync :sync))
                (fname (intern (format "pdd-test-<%s>-%s%s" name backend sync))))
           `(ert-deftest ,fname ()
              ,(unless (or (memq backend forbidens)
                           (memq sync forbidens)
                           (memq (intern (format "%s%s" backend sync)) forbidens))
                 `(let* ,@(let* ((letv (when (memq (caar body) '(let let*)) (cadar body)))
                                 (bodyv (if letv (nthcdr 2 (car body)) body)))
                            `(((pdd-sync ,sync) ,@letv)
                              ,@(mapcar (lambda (expr)
                                          (setq expr (walk-inject expr backend sync))
                                          (when (eq (car expr) 'should)
                                            (setq expr `(,(pop expr) (let (it) ,(pop expr) ,@expr))))
                                          expr)
                                        bodyv)))))))))
    `(progn ,@(cl-loop for c in pdd-test-backends
                       collect (deftest c :sync)
                       collect (deftest c :async)))))


;;; Common Tests

(ert-deftest pdd-test--detect-charset ()
  (should (equal (pdd-detect-charset 'application/json) 'utf-8))
  (should (equal (pdd-detect-charset "application/json") 'utf-8))
  (should (equal (pdd-detect-charset "application/json;charset=gbk") 'gbk))
  (should (equal (pdd-detect-charset "text/html; x=3,  charset=gbk") 'gbk)))

(ert-deftest pdd-test-format-formdata ()
  (should (equal (pdd-format-formdata nil) ""))
  (should (equal (let ((pdd-multipart-boundary "666")) (pdd-format-formdata '((a . 1))))
                 "--666\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--666--"))
  (should (string-match-p "--666\r
Content-Disposition: form-data; name=\"name\"\r
\r
John\r
--666\r
Content-Disposition: form-data; name=\"age\"\r
\r
30\r
--666\r
Content-Disposition: form-data; name=\"file\"; filename=\"pdd-test-.*.txt\"\r
Content-Type: application/octet-stream\r
\r
test\r\n--666--" (let ((pdd-multipart-boundary "666")
                       (temp-file (make-temp-file "pdd-test-" nil ".txt" "test")))
                   (unwind-protect
                       (pdd-format-formdata `(("name" . "John") ("age" . "30") (file ,temp-file)))
                     (delete-file temp-file))))))

(ert-deftest pdd-test-parse-set-cookie ()
  (should (equal (pdd-parse-set-cookie
                  "__session-Id=38afes7a8; SameSite=None; Secure; Path=/; Partitioned;")
                 '(:name "__session-Id" :value "38afes7a8" :samesite "none" :secure t :path "/" :partitioned t :host-only t)))
  (should (equal (cl-loop for (k v) on
                          (pdd-parse-set-cookie
                           "id=a3fWa; Expires=Wed, 21 Oct 2015 07:28:00 GMT;  max-Age=2592000;Secure; Path=/; Domain=example.com")
                          by #'cddr unless (eq k :created-at) append (list k v))
                 '(:name "id" :value "a3fWa" :expires (22055 16000) :max-age 2592000 :secure t :path "/" :domain "example.com"))))

(ert-deftest pdd-test-task-then ()
  (should (let* ((t1 (pdd-resolve 41))
                 (then (pdd-then t1
                         (lambda (v) (+ v 1))
                         (lambda (e) e))))
            (equal (aref then 2) (list 42)))))

(ert-deftest pdd-test-funcall ()
  (should (equal (pdd-funcall (lambda (x y) (list x y)) '(1 2 3 4 :a 22 :b 33))
                 (list 1 2)))
  (should (equal (pdd-funcall (lambda (&key a b) (list a b)) '(1 2 3 4 :a 22 :b 33))
                 (list 22 33)))
  (should (equal (pdd-funcall (lambda (x &key b) (list x b)) '(1 2 3 4 :a 22 :b 33))
                 (list 1 33))))

(ert-deftest pdd-test-cacher-key ()
  (should (equal (pdd-cacher-resolve-key "~/" '(a b c)) "6ef2031afe7508735e243afd96fbe4b3"))
  (should (equal (pdd-cacher-resolve-key "~/" "hello.") "hello."))
  (should (equal (pdd-cacher-resolve-key (make-hash-table) '(a b c)) '(a b c)))
  (should (equal (pdd-cacher-resolve-key (make-hash-table) "hello.") "hello."))
  (let ((c1 (pdd-cacher :key (lambda () "abc") :store (make-hash-table)))
        (c2 (pdd-cacher :key (lambda () "abc") :store "~/"))
        (c3 (pdd-cacher :key (lambda (k) (cons 1 k)) :store (make-hash-table)))
        (c4 (pdd-cacher :key (lambda (k) (concat "-" k)) :store "~/"))
        (c5 (pdd-cacher :key '(xxx (data . b)) :store (make-hash-table)))
        (c6 (pdd-cacher :key '(xxx (data . b)) :store "~/")))
    (should (equal (pdd-cacher-resolve-key c1 '(a b c)) "abc"))
    (should (equal (pdd-cacher-resolve-key c2 '(a b c)) "abc"))
    (should (equal (pdd-cacher-resolve-key c3 '(a b c)) '(1 a b c)))
    (should (equal (pdd-cacher-resolve-key c4 "hello.") "-hello."))
    (should (equal (pdd-cacher-resolve-key c5 (pdd-request :backend pdd-backend :url "kk" :data '((a . 1) (b . 2)))) '(xxx 2)))
    (should (equal (pdd-cacher-resolve-key c6 (pdd-request :backend pdd-backend :url "kk" :data '((a . 1) (b . 2)))) "f341eda5609d62686e569ef42819865b"))))

(ert-deftest pdd-test-cacher-hashtable ()
  (let ((ht (make-hash-table :test #'equal)))
    (should (pdd-cacher-put ht "k1" "hello1"))
    (should (pdd-cacher-put ht '(a b c) "hello2" (+ (float-time) 3000)))
    (should (pdd-cacher-put ht 'expired "hello3" (- (float-time) 100)))
    (should (equal (pdd-cacher-get ht "k1") "hello1"))
    (should (equal (pdd-cacher-get ht '(a b c)) "hello2"))
    (pdd-cacher-clear ht '(a b c))
    (should (equal (pdd-cacher-get ht "k1") "hello1"))
    (should-not (pdd-cacher-get ht '(a b c)))
    (should-not (pdd-cacher-get ht 'expired))))

(ert-deftest pdd-test-cacher-directory ()
  (let ((dir (make-temp-file "pdd-tests-cacher-" t)))
    (unwind-protect
        (progn
          (should (pdd-cacher-put dir "k1" "hello1"))
          (should (pdd-cacher-put dir '(a b c) "hello2" (+ (float-time) 3000)))
          (should (pdd-cacher-put dir 'expired "hello3" (- (float-time) 1000)))
          (should (equal (pdd-cacher-get dir "k1") "hello1"))
          (should (equal (pdd-cacher-get dir '(a b c)) "hello2"))
          (pdd-cacher-clear dir '(a b c))
          (should (equal (pdd-cacher-get dir "k1") "hello1"))
          (should-not (pdd-cacher-get dir '(a b c)))
          (should-not (pdd-cacher-get dir 'expired)))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest pdd-test-cacher-request ()
  (let ((dir (make-temp-file "pdd-tests-cacher-" t)))
    (unwind-protect
        (let* ((ht (make-hash-table :test #'equal))
               (req (pdd-request :backend pdd-backend :url "https://httpbin.org/ip" :data '((data . 1) (data . 2))))
               (c1 (pdd-cacher :store ht :key '(xxx (data . b))))
               (c2 (pdd-cacher :store dir :key '(xxx (data . b)))))
          (should (pdd-cacher-put c1 req "hello1"))
          (should (pdd-cacher-put c2 req "hello2"))
          (should (equal (pdd-cacher-get c1 req) "hello1"))
          (should (equal (pdd-cacher-get c2 req) "hello2")))
      (ignore-errors (delete-directory dir t)))))


;;; Request Tests

(ert-deftest pdd-test-basic-request ()
  (should (eq 'user-agent (caar (pdd-test-req url "/user-agent"))))
  (should (eq 'user-agent (caar (pdd-test-req curl "/user-agent")))))

(pdd-deftests params ()
  (should (pdd "/get"
            :params '((a . 1) (b . 2))
            :done (lambda (r) (setq it r)))
          (and (equal (alist-get 'a (alist-get 'args it)) "1")
               (equal (alist-get 'b (alist-get 'args it)) "2")))
  (should (pdd "/get"
            :params "a=1&b=2"
            :done (lambda (r) (setq it r)))
          (and (equal (alist-get 'a (alist-get 'args it)) "1")
               (equal (alist-get 'b (alist-get 'args it)) "2"))))

(pdd-deftests params-edge ()
  (should (pdd "/post" :data "" :done (lambda (r) (setq it r)))
          (equal (alist-get 'data it) ""))
  (should (pdd "/get" :params nil :done (lambda (r) (setq it r)))
          (equal (alist-get 'args it) nil)))

(pdd-deftests done-1arg ()
  (should (pdd "/uuid" :done (lambda (rs) (setq it rs)))
          (= 36 (length (cdar it)))))

(pdd-deftests done-2arg ()
  (should (pdd "/uuid" :done (lambda (_ _ c) (setq it c)))
          (= it 200))
  (should (pdd "/post" :data '((k . v)) :done (lambda (_ _ c) (setq it c)))
          (= it 200)))

(pdd-deftests done-3arg ()
  (should (pdd "/uuid" :done (lambda (_ _ _ v) (setq it v)))
          (string-match-p "^[12]" it)))

(pdd-deftests done-4arg ()
  (should (pdd "/uuid" :done (lambda (_ hs) (setq it hs)))
          (alist-get 'date it)))

(pdd-deftests headers-get ()
  (should (pdd "/get"
            :headers `((bear ,"hello") ua-emacs www-url ("X-Test" . "welcome"))
            :done (lambda (r) (setq it r)))
          (cl-flet ((k=v (k v) (equal (alist-get k (alist-get 'headers it)) v)))
            (and
             (k=v 'Content-Type "application/x-www-form-urlencoded")
             (k=v 'X-Test "welcome")
             (k=v 'User-Agent "Emacs Agent")
             (k=v 'Authorization "Bearer hello")))))

(pdd-deftests headers-post ()
  (should (pdd "/post" :data '((a . 1)) :done (lambda (r) (setq it r)))
          (equal (cdar (alist-get 'form it)) "1"))
  (should (pdd "/post" :headers '(json) :data '((a . 1)) :done (lambda (r) (setq it r)))
          (equal (alist-get 'data it) "{\"a\":1}"))
  (should (pdd "/post" :headers '(www-url) :data '((a . 1)) :done (lambda (r) (setq it r)))
          (equal (cdar (alist-get 'form it)) "1"))
  (should (pdd "/post" :headers '(("content-type" . "")) :data '((a . 1)) :done (lambda (r) (setq it r)))
          (equal (alist-get 'data it) "a=1")))

(pdd-deftests content-length ()
  (should (pdd "/ip" :as #'identity :done (lambda (r h) (setq it (cons r h))))
          (should (= (string-to-number (alist-get 'content-length (cdr it)))
                     (length (car it)))))
  (should (pdd "/post"
            :as #'identity
            :data '((a . "hello, world, 你好啊"))
            :done (lambda (r h) (setq it (cons r h))))
          (should (= (string-to-number (alist-get 'content-length (cdr it)))
                     (length (car it))))))

(pdd-deftests method-put ()
  (should (pdd "/put"
            :method 'put
            :data '((k . v))
            :done (lambda (r) (setq it r)))
          (equal (alist-get 'k (alist-get 'form it)) "v")))

;; There is problem with plz's patch
(pdd-deftests method-patch (curl)
  (should (pdd "/patch"
            :method 'patch
            :data '((k . v))
            :done (lambda (r) (setq it r)))
          (equal (alist-get 'k (alist-get 'form it)) "v")))

(pdd-deftests method-delete ()
  (should (pdd "/delete"
            :method 'delete
            :params '((a . 2))
            :done (lambda (rs) (setq it rs)))
          (equal (cdar (alist-get 'args it)) "2")))

(pdd-deftests streaming ()
  (let ((chunks 0))
    (should (pdd "/stream-bytes/100"
              :peek (lambda () (cl-incf chunks))
              :done (lambda (r) (setq it r)))
            (and (>= chunks 1) (= (length it) 100)))))

(pdd-deftests fine ()
  (should (ignore-errors
            (pdd "/uuid"
              :done (lambda () (car--- r))
              :fine (lambda () (setq it 666))))
          (equal it 666))
  (should (ignore-errors
            (pdd "/uuid"
              :done (lambda (rs) ())
              :fine (lambda (rs) (setq it rs))))
          (cl-typep it #'pdd-request))
  (should (ignore-errors
            (pdd "/uuid"
              :done (lambda () (car--- r))
              :fail (lambda () (car--- r))
              :fine (lambda () (setq it 676))))
          (equal it 676)))

(pdd-deftests binary-data ()
  (should (pdd "/bytes/100" :done (lambda (raw) (setq it raw)))
          (= (length it) 100))
  (should (pdd "/stream-bytes/100" :done (lambda (raw) (setq it raw)))
          (= (length it) 100)))

(pdd-deftests download-bytes ()
  (should (pdd "/bytes/1024" :done (lambda (data) (setq it data)))
          (= (length it) 1024)))

(pdd-deftests download-image ()
  (should (pdd "/image/jpeg" :done (lambda (raw) (setq it raw)))
          (equal 'jpeg (image-type-from-data it))))

(pdd-deftests upload ()
  (let* ((fname (make-temp-file "pdd-"))
         (_buffer (with-temp-file fname (insert "hello"))))
    (should (pdd "/post"
              :data `((from . lorniu) (f ,fname) (to . where))
              :done (lambda (r) (setq it r)))
            (ignore-errors (delete-file fname))
            (and (equal (alist-get 'f (alist-get 'files it)) "hello")
                 (equal (alist-get 'to (alist-get 'form it)) "where")))))

(pdd-deftests authentication ()
  (should (pdd "/basic-auth/user/passwd"
            :headers '((basic "dXNlcjpwYXNzd2Q="))
            :done (lambda (r) (setq it r)))
          (and (equal (alist-get 'user it) "user")
               (equal (alist-get 'authenticated it) t))))

;; connect-timeout not act as same, should be improved
(pdd-deftests timeout-and-retry (curl)
  (let ((retry-count 0) finished)
    (should (pdd "/delay/2"
              :timeout 1 :max-retry 0
              :fail (lambda (err) (setq it (format "%s" err))))
            (string-match-p "408\\|timeout" it))
    (should (pdd "/delay/3"
              :init (lambda () (cl-incf retry-count))
              :timeout 2 :max-retry 2
              :fail (lambda (&key text code) (setq it (cons text code)))
              :fine (lambda () (setq finished t)))
            (while (not finished) (sleep-for 0.2))
            (and (string-match-p "timeout\\|408" (format "%s" it))
                 (= retry-count 3)))))

(pdd-deftests http-error-404 ()
  (should (pdd "/status/404" :fail (lambda (&key text code) (setq it (cons text code))))
          (equal it (cons "Not found" 404))))

(pdd-deftests http-error-500 ()
  (should (pdd "/status/500" :fail (lambda (&key text code) (setq it (cons text code))))
          (equal it (cons "Internal server error" 500))))

;; There is a wrong return response header bug in plz
(pdd-deftests redirect (curl)
  (let (finished)
    (should (pdd "/redirect-to?url=/get"
              :done (lambda (r) (setq it r))
              :fine (lambda () (setq finished t)))
            (while (not finished) (sleep-for 0.2))
            (string-suffix-p "/get" (alist-get 'url it)))
    (should (pdd "/redirect/1"
              :init (setq finished nil)
              :done (lambda (r) (setq it r))
              :fine (lambda () (setq finished t)))
            (while (not finished) (sleep-for 0.2))
            (string-suffix-p "/get" (alist-get 'url it)))))

(pdd-deftests cookies ()
  (let ((cj (pdd-cookie-jar)))
    (should (pdd "https://postman-echo.com/get" :cookie-jar cj)
            (equal "sails.sid" (plist-get (cadar (oref cj cookies)) :name)))
    (pdd-cookie-jar-put cj "postman-echo.com" '(:name "hello" :value "666"))
    (should (pdd "https://postman-echo.com/get" :cookie-jar cj :done (lambda (r) (setq it r)))
            (string-match-p "hello=666" (alist-get 'cookie (alist-get 'headers it))))))

(provide 'pdd-tests)

;;; pdd-tests.el ends here
