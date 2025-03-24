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

;;; Code:

(require 'ert)
(require 'pdd)
(require 'plz)

(defconst pdd-test-clients '(url plz))

(defvar pdd-test-host "https://httpbin.org")

;;(setq pdd-base-url pdd-test-host)
;;(setq pdd-default-sync :sync)
;;(setq pdd-default-sync :async)
;;(setq pdd-default-client (pdd-url-client))
;;(setq pdd-default-client (pdd-plz-client))

(defun pdd-block-and-wait-proc (proc)
  (cl-loop while (ignore-errors (buffer-live-p (process-buffer proc)))
           do (sleep-for 0.2)))

(defmacro pdd-test-req (client &rest args)
  "Wrap `pdd' to ease tests."
  (declare (indent 1))
  `(let ((pdd-base-url ,pdd-test-host)
         (pdd-default-client (,(intern (format "pdd-%s-client" client)))))
     (pdd ,@args)))

(cl-defmacro pdd-deftests (name (&rest forbidens) &rest body)
  "Build test functions, cover all the cases by composing url/plz and sync/aync."
  (declare (indent 2))
  (cl-labels
      ((walk-inject (expr client sync)
         (cond
          ((and (consp expr) (eq (car expr) 'pdd))
           `(let ((proc (pdd-test-req ,client ,@(cdr expr))))
              ,(if (eq :async sync) `(pdd-block-and-wait-proc proc))))
          ((consp expr)
           (cons (walk-inject (car expr) client sync)
                 (walk-inject (cdr expr) client sync)))
          (t expr)))
       (deftest (client sync)
         (let* ((sync (or sync :sync))
                (fname (intern (format "pdd-test-%s--%s%s" name client sync))))
           `(ert-deftest ,fname ()
              ,(unless (or (memq client forbidens)
                           (memq sync forbidens)
                           (memq (intern (format "%s%s" client sync)) forbidens))
                 `(let ((pdd-default-sync ,sync))
                    ,@(mapcar (lambda (expr)
                                (let ((sd (if (memq (car expr) '(let let*)) (caddr expr) expr)))
                                  (setq sd (walk-inject sd client sync))
                                  (setq sd `(should (let (it) ,(cadr sd) ,@(cddr sd))))
                                  (if (eq (car expr) 'should) sd
                                    `(,(car expr) ,(cadr expr) ,sd))))
                              body)))))))
    `(progn ,@(cl-loop for c in pdd-test-clients
                       collect (deftest c :sync)
                       collect (deftest c :async)))))

;;; Request Tests

(ert-deftest pdd-test-basic-request ()
  (should (eq 'user-agent (caar (pdd-test-req url "/user-agent"))))
  (should (eq 'user-agent (caar (pdd-test-req plz "/user-agent")))))

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

(pdd-deftests method-put ()
  (should (pdd "/put"
            :method 'put
            :data '((k . v))
            :done (lambda (r) (setq it r)))
          (equal (alist-get 'k (alist-get 'form it)) "v")))

;; There is problem with plz's patch
(pdd-deftests method-patch (plz)
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
              :filter (lambda () (cl-incf chunks))
              :done (lambda (r) (setq it r)))
            (and (>= chunks 1) (= (length it) 100)))))

(pdd-deftests binary-data ()
  (should (pdd "/bytes/100" :done (lambda (raw) (setq it raw)))
          (= (length it) 100))
  (should (pdd "/stream-bytes/100" :done (lambda (raw) (setq it raw)))
          (= (length it) 100)))

;; The data download with plz not always has enough length of 1024
;; Maybe a bug, I don't know, but don't want to debug
(pdd-deftests download-bytes (plz)
  (should (pdd "/bytes/1024" :done (lambda (data) (setq it (length data))))
          (= it 1024)))

(pdd-deftests download-image ()
  (should (pdd "/image/jpeg" :done (lambda (raw) (setq it raw)))
          (equal 'jpeg (image-type-from-data it))))

(pdd-deftests upload ()
  (let* ((fname (make-temp-file "pdd-"))
         (_buffer (with-temp-file fname (insert "hello"))))
    (should (pdd "/post"
              :data `((from . lorniu) (f ,fname))
              :done (lambda (r) (setq it r)))
            (ignore-errors (delete-file fname))
            (equal (cdar (alist-get 'form it)) "hello"))))

(pdd-deftests authentication ()
  (should (pdd "/basic-auth/user/passwd"
            :headers '((basic "dXNlcjpwYXNzd2Q="))
            :done (lambda (r) (setq it r)))
          (and (equal (alist-get 'user it) "user")
               (equal (alist-get 'authenticated it) t))))

(pdd-deftests timeout-and-retry ()
  (let ((retry-count 0))
    (should (pdd "/delay/2"
              :timeout 1 :retry 0
              :fail (lambda (r c) (setq it (format "%s%s" r c))))
            (string-match-p "408\\|timeout" it))
    (should (pdd "/delay/2"
              :timeout 1 :retry 2
              :fail (lambda (r c) (cl-incf retry-count) (setq it (cons r c))))
            (and (string-match-p "timeout\\|408" (format "%s" it))
                 (= retry-count 2)))))

(pdd-deftests http-error-404 ()
  (should (pdd "/status/404" :fail (lambda (e c) (setq it (cons e c))))
          (equal it (cons "Not found" 404))))

(pdd-deftests http-error-500 ()
  (should (pdd "/status/500" :fail (lambda (e c) (setq it (cons e c))))
          (equal it (cons "Internal server error" 500))))

;; Inhibit this test at present
;; FIXME: there is response parse bug in plz, patch is needed later?
(pdd-deftests redirect (plz)
  (should (pdd "/redirect-to?url=/get" :done (lambda (r) (setq it r)))
          (string-suffix-p "/get" (alist-get 'url it)))
  (should (pdd "/redirect/1" :done (lambda (r) (setq it r)))
          (string-suffix-p "/get" (alist-get 'url it))))

(provide 'pdd-tests)

;;; pdd-tests.el ends here
