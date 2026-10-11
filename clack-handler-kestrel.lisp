;;; clack-handler-kestrel.lisp -- a Clack handler for dotcl, on ASP.NET Core's Kestrel.
;;;
;;; Through Clack:
;;;
;;;   (clack:clackup app :server :kestrel :port 5000)
;;;
;;; Or without Clack, on a plain Lack application:
;;;
;;;   (clack.handler.kestrel:start app :port 5000)   ; => server, does not block
;;;   (clack.handler.kestrel:stop server)
;;;
;;; The request body is read before the application is called and the response is
;;; written after it returns, both through .NET's asynchronous API. Kestrel
;;; refuses synchronous stream operations by default and it is right to: a
;;; handler waiting on a socket holds a thread pool thread. Because a Lack
;;; application hands back its body as a value rather than writing as it goes,
;;; neither direction has to happen while the application runs, so the
;;; prohibition never comes up. :raw-body is therefore a stream over bytes
;;; already in memory. Pass :allow-synchronous-io t to hand over Kestrel's own
;;; stream instead, which an application streaming a large upload will want.

#-dotcl
(error "clack-handler-kestrel runs only on dotcl.")

(defpackage :clack.handler.kestrel
  (:use :cl)
  (:nicknames :clack/handler/kestrel)
  (:export #:run
           #:start
           #:stop))

(in-package :clack.handler.kestrel)

(dotnet:load-assembly "Microsoft.AspNetCore")
(dotnet:load-assembly "Microsoft.Extensions.Logging")

(defvar *header-dictionary* "Microsoft.AspNetCore.Http.IHeaderDictionary"
  "Headers are reached through this interface: the concrete types implement it
and IDictionary separately, so the one meant has to be named.")

(defun %headers (collection)
  (dotnet:cast collection *header-dictionary*))

(defun %feature (context type-name)
  (dotnet:invoke (dotnet:invoke context "Features") "Item"
                 (dotnet:resolve-type type-name)))

(defun %header-value (headers name)
  "The value of NAME as a string, or NIL when the header is absent."
  (let ((value (dotnet:invoke headers "Item" name)))
    (when value
      (let ((text (dotnet:invoke value "ToString")))
        (unless (string= text "") text)))))

(defun %request-headers (request)
  "A hash table of every request header, keyed by lower-case name. A header
given more than once has its values joined with commas."
  (let ((table (make-hash-table :test #'equal))
        (iterator (dotnet:invoke (dotnet:invoke request "Headers") "GetEnumerator")))
    (loop while (dotnet:invoke iterator "MoveNext")
          do (let ((pair (dotnet:invoke iterator "Current")))
               (setf (gethash (string-downcase (dotnet:invoke pair "Key")) table)
                     (dotnet:invoke (dotnet:invoke pair "Value") "ToString"))))
    table))

(defun %keyword (string)
  (intern (string-upcase string) :keyword))

(defun %read-body (context allow-synchronous-io)
  "The request body as a CL input stream of bytes.

Copied into memory first, so the application reads without touching Kestrel's
stream. With ALLOW-SYNCHRONOUS-IO that stream is handed over instead."
  (let ((body (dotnet:invoke (dotnet:invoke context "Request") "Body")))
    (cond
      (allow-synchronous-io
       (let ((feature (%feature context
                                "Microsoft.AspNetCore.Http.Features.IHttpBodyControlFeature")))
         (when feature
           (setf (dotnet:invoke feature "AllowSynchronousIO") t)))
       (dotnet:to-stream body :binary t))
      (t
       (let ((buffer (dotnet:new "System.IO.MemoryStream")))
         (dotnet:await (dotnet:invoke body "CopyToAsync" buffer))
         (setf (dotnet:invoke buffer "Position") 0)
         (dotnet:to-stream buffer :binary t))))))

(defun %environment (context allow-synchronous-io)
  "The request as a Lack environment plist."
  (let* ((request (dotnet:invoke context "Request"))
         (connection (dotnet:invoke context "Connection"))
         (headers (%headers (dotnet:invoke request "Headers")))
         (host (dotnet:invoke request "Host"))
         (query (dotnet:invoke (dotnet:invoke request "QueryString") "Value"))
         (raw-target (dotnet:invoke
                      (%feature context "Microsoft.AspNetCore.Http.Features.IHttpRequestFeature")
                      "RawTarget"))
         (length (%header-value headers "content-length"))
         (address (dotnet:invoke connection "RemoteIpAddress")))
    (list :request-method (%keyword (dotnet:invoke request "Method"))
          :script-name ""
          :path-info (or (dotnet:invoke (dotnet:invoke request "Path") "Value") "")
          :query-string (when (and query (> (length query) 1))
                          (subseq query 1))
          :request-uri raw-target
          :server-protocol (%keyword (dotnet:invoke request "Protocol"))
          :url-scheme (string-downcase (dotnet:invoke request "Scheme"))
          :server-name (or (dotnet:invoke host "Host") "")
          :server-port (or (dotnet:invoke host "Port")
                           (dotnet:invoke connection "LocalPort"))
          :remote-addr (if address (dotnet:invoke address "ToString") "")
          :remote-port (dotnet:invoke connection "RemotePort")
          :content-type (%header-value headers "content-type")
          :content-length (when length (parse-integer length :junk-allowed t))
          :headers (%request-headers request)
          :raw-body (%read-body context allow-synchronous-io)
          :clack.streaming t)))

(defun %write-headers (response status headers)
  "Set STATUS and apply a Lack header plist. A name given twice is sent twice,
as Set-Cookie needs."
  (setf (dotnet:invoke response "StatusCode") status)
  (let ((collection (%headers (dotnet:invoke response "Headers"))))
    (loop for (name value) on headers by #'cddr
          for text = (string-downcase (string name))
          when value
            do (if (string= text "content-type")
                   (setf (dotnet:invoke response "ContentType") (princ-to-string value))
                   (dotnet:static "Microsoft.AspNetCore.Http.HeaderDictionaryExtensions"
                                  "Append" collection text (princ-to-string value))))))

(defun %octets (vector start end)
  (let ((end (or end (length vector))))
    (if (and (typep vector '(simple-array (unsigned-byte 8) (*)))
             (= start 0) (= end (length vector)))
        vector
        (coerce (subseq vector start end) '(simple-array (unsigned-byte 8) (*))))))

(defun %write-chunk (response chunk &key (start 0) end)
  "Write a string (as UTF-8) or a vector of octets."
  (etypecase chunk
    (null nil)
    (string
     (dotnet:await (dotnet:invoke response "WriteAsync"
                                  (if (or (plusp start) end) (subseq chunk start end) chunk))))
    ((vector (unsigned-byte 8))
     (let ((octets (%octets chunk start end)))
       (dotnet:await (dotnet:invoke (dotnet:invoke response "Body") "WriteAsync"
                                    octets 0 (length octets)))))))

(defun %write-body (response body)
  "Send BODY: a list of strings or octet vectors, a single string, an octet
vector, or a pathname."
  (etypecase body
    (pathname
     (dotnet:load-assembly "Microsoft.AspNetCore.Http.Extensions")
     (dotnet:await (dotnet:static "Microsoft.AspNetCore.Http.SendFileResponseExtensions"
                                  "SendFileAsync" response (namestring (truename body)))))
    (list (dolist (chunk body)
            (%write-chunk response chunk)))
    ((or string (vector (unsigned-byte 8)))
     (%write-chunk response body))))

(defun %report (condition)
  (ignore-errors
   (format *error-output* "~&clack-handler-kestrel: ~a~%" condition)
   (finish-output *error-output*)))

(defun %fail (response condition debug)
  "Answer 500 unless the response has already started going out."
  (%report condition)
  (unless (dotnet:invoke response "HasStarted")
    (ignore-errors
     (%write-headers response 500 (list :content-type "text/plain; charset=utf-8"))
     (%write-chunk response (if debug
                                (format nil "Internal Server Error~%~%~a~%" condition)
                                "Internal Server Error")))))

(defun %handle (context application allow-synchronous-io debug)
  "Serve one request. Returns the task Kestrel waits on before it ends the
response: already complete for an ordinary response, completed by the writer's
:close for a streaming one."
  (let* ((response (dotnet:invoke context "Response"))
         (done (dotnet:new "System.Threading.Tasks.TaskCompletionSource"))
         (task (dotnet:invoke done "Task")))
    (flet ((finish () (dotnet:invoke done "TrySetResult")))
      (flet ((respond (result)
               (destructuring-bind (status headers &optional (body nil body-p)) result
                 (%write-headers response status headers)
                 (cond
                   (body-p
                    (unwind-protect (%write-body response body)
                      (finish))
                    nil)
                   (t
                    (lambda (chunk &key (start 0) end close)
                      (let ((written nil))
                        (unwind-protect
                             (progn
                               (%write-chunk response chunk :start start :end end)
                               (dotnet:await (dotnet:invoke (dotnet:invoke response "Body")
                                                            "FlushAsync"))
                               (setf written t))
                          (when (or close (not written)) (finish))))))))))
        (handler-case
            (let ((result (funcall application (%environment context allow-synchronous-io))))
              (etypecase result
                (list (respond result))
                (function (funcall result #'respond))))
          (error (condition)
            (%fail response condition debug)
            (finish)))))
    task))

(defun %url (address port)
  (format nil "http://~a:~a"
          (if (and (find #\: address) (char/= (char address 0) #\[))
              (format nil "[~a]" address)
              address)
          port))

(defun %make-server (app &key (port 5000) (address "127.0.0.1") debug allow-synchronous-io
                    &allow-other-keys)
  "A Kestrel server for APP, configured but not yet started."
  (let* ((builder (dotnet:static "Microsoft.AspNetCore.Builder.WebApplication" "CreateBuilder"))
         (server (progn
                   (dotnet:static "Microsoft.Extensions.Logging.LoggingBuilderExtensions"
                                  "ClearProviders" (dotnet:invoke builder "Logging"))
                   (dotnet:invoke builder "Build"))))
    (dotnet:invoke (dotnet:invoke server "Urls") "Add" (%url address port))
    (dotnet:static "Microsoft.AspNetCore.Builder.RunExtensions" "Run" server
                   (dotnet:make-delegate "Microsoft.AspNetCore.Http.RequestDelegate"
                                         (lambda (context)
                                           (%handle context app allow-synchronous-io debug))))
    server))

(defun start (app &rest args &key port address debug allow-synchronous-io &allow-other-keys)
  "Serve the Lack application APP on ADDRESS:PORT and return the server, which
STOP takes. Returns once the server is listening; requests are served on .NET
thread pool threads. PORT defaults to 5000 and ADDRESS to \"127.0.0.1\".

On an error in APP the client gets a 500 and the error is printed to
*ERROR-OUTPUT*; with DEBUG the response body also carries the error message."
  (declare (ignore port address debug allow-synchronous-io))
  (let ((server (apply #'%make-server app args)))
    (dotnet:await (dotnet:invoke server "StartAsync"))
    server))

(defun stop (server)
  "Stop SERVER and wait for it to finish. Stopping a stopped server does nothing."
  (dotnet:await (dotnet:invoke server "StopAsync"))
  t)

(defun run (app &rest args &key port address debug allow-synchronous-io &allow-other-keys)
  "The Clack entry point: start the server, block until it stops, and return
it. Unwinding out of the wait stops the server, which is how CLACK:STOP (by
destroying the thread RUN is on) ends it; STOP from another thread also ends
the wait."
  (declare (ignore port address debug allow-synchronous-io))
  (let ((server (apply #'%make-server app args))
        (stopping (dotcl:make-semaphore))
        (starting nil))
    (dotnet:invoke (dotnet:invoke (dotnet:invoke server "Lifetime") "ApplicationStopping")
                   "Register"
                   (dotnet:make-delegate "System.Action"
                                         (lambda () (dotcl:signal-semaphore stopping))))
    (unwind-protect
         (progn
           ;; DESTROY-THREAD interrupts whatever blocking wait this thread is in,
           ;; .NET's own included. Starting on a pool thread keeps the start out
           ;; of its reach: only the wait for it here can be cut short.
           (setf starting
                 (dotnet:static "System.Threading.Tasks.Task" "Run"
                                (dotnet:make-delegate
                                 "System.Func`1[System.Threading.Tasks.Task]"
                                 (lambda () (dotnet:invoke server "StartAsync")))))
           (dotnet:await starting)
           (dotcl:wait-on-semaphore stopping))
      (when starting
        ;; A server still starting would begin listening after the stop, so
        ;; let the start finish first.
        (ignore-errors (dotnet:await starting))
        (stop server)))
    server))
