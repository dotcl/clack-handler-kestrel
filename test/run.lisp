;;; Run the checks: `dotcl test/run.lisp < /dev/null` from the repository root.
;;;
;;; Needs the ASP.NET Core shared framework, and Clack and Lack from Quicklisp.
;;; Exits 0 when every check passes.

(require "asdf")
(require "quicklisp")
(asdf:load-asd (merge-pathnames "../clack-handler-kestrel.asd" *load-truename*))
(funcall (find-symbol "QUICKLOAD" "QL")
         '("clack-handler-kestrel" "clack" "lack" "lack-middleware-static")
         :silent t)
(load (merge-pathnames "checks.lisp" *load-truename*))
