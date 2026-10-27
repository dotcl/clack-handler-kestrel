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
;;; written after it returns, both through .NET's asynchronous API, and the
;;; request's task is handed back to Kestrel while either is pending: a handler
;;; waiting on a socket would hold a thread pool thread, and a few hundred slow
;;; clients would hold them all. Because a Lack application hands back its body
;;; as a value rather than writing as it goes, neither direction has to happen
;;; while the application runs, so Kestrel's prohibition of synchronous stream
;;; operations never comes up. :raw-body is therefore a stream over bytes
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

(eval-when (:compile-toplevel :load-toplevel :execute)
  (dotnet:load-assembly "Microsoft.AspNetCore")
  (dotnet:load-assembly "Microsoft.AspNetCore.Server.Kestrel")
  (dotnet:load-assembly "Microsoft.AspNetCore.Server.Kestrel.Core")
  (dotnet:load-assembly "Microsoft.Extensions.Logging")
  ;; Loaded here so that the compiler can resolve the types *TYPES* names.
  (dotnet:load-assembly "Microsoft.AspNetCore.Http.Abstractions")
  (dotnet:load-assembly "Microsoft.AspNetCore.Http.Features")
  (dotnet:load-assembly "Microsoft.Extensions.Primitives")

  (defparameter *types*
    '(:context "Microsoft.AspNetCore.Http.HttpContext"
      :request "Microsoft.AspNetCore.Http.HttpRequest"
      :response "Microsoft.AspNetCore.Http.HttpResponse"
      :connection "Microsoft.AspNetCore.Http.ConnectionInfo"
      :headers "Microsoft.AspNetCore.Http.IHeaderDictionary"
      :header-enumerator "System.Collections.Generic.IEnumerator`1[[System.Collections.Generic.KeyValuePair`2[[System.String],[Microsoft.Extensions.Primitives.StringValues]]]]"
      :header-pair "System.Collections.Generic.KeyValuePair`2[[System.String],[Microsoft.Extensions.Primitives.StringValues]]"
      :string-values "Microsoft.Extensions.Primitives.StringValues"
      :path "Microsoft.AspNetCore.Http.PathString"
      :query "Microsoft.AspNetCore.Http.QueryString"
      :host "Microsoft.AspNetCore.Http.HostString"
      :address "System.Net.IPAddress"
      :features "Microsoft.AspNetCore.Http.Features.IFeatureCollection"
      :request-feature "Microsoft.AspNetCore.Http.Features.IHttpRequestFeature"
      :body-detection "Microsoft.AspNetCore.Http.Features.IHttpRequestBodyDetectionFeature"
      :task "System.Threading.Tasks.Task"
      :stream "System.IO.Stream"
      :memory-stream "System.IO.MemoryStream"
      :string "System.String"
      :int "System.Int32"
      :long "System.Int64"
      :type "System.Type"))

  (defun %the (type form)
    `(the (dotnet ,(or (getf *types* type) (error "No .NET type ~s" type))) ,form)))

(defmacro %call (type object member &rest args)
  "OBJECT's MEMBER, OBJECT being of the .NET type TYPE (a key of *TYPES*). Each
argument is written (type form). With every type known the compiler calls the
member directly instead of looking it up by name at each call. A property is
reached through its accessor, get_X or set_X; an indexer is get_Item on an
IHeaderDictionary, which has more than one."
  `(dotnet:invoke ,(%the type object) ,member
                  ,@(mapcar (lambda (arg) (%the (first arg) (second arg))) args)))

(defvar *header-dictionary* "Microsoft.AspNetCore.Http.IHeaderDictionary"
  "Response headers are appended through this interface: the concrete types
implement it and IDictionary separately, so the one meant has to be named.")

(defvar *completed-task* (dotnet:static "System.Threading.Tasks.Task" "CompletedTask"))

(defvar *no-cancellation* (dotnet:static "System.Threading.CancellationToken" "None"))

(defvar *no-body* (dotnet:static "System.IO.Stream" "Null"))

(defvar *body-detection*
  (dotnet:resolve-type "Microsoft.AspNetCore.Http.Features.IHttpRequestBodyDetectionFeature"))

(defvar *request-feature*
  (dotnet:resolve-type "Microsoft.AspNetCore.Http.Features.IHttpRequestFeature"))

(defun %header-value (headers name)
  "The value of NAME as a string, or NIL when the header is absent."
  (let ((text (%call :string-values (%call :headers headers "get_Item" (:string name))
                     "ToString")))
    (unless (string= text "") text)))

(defun %request-headers (request)
  "A hash table of every request header, keyed by lower-case name. A header
given more than once has its values joined with commas."
  (let ((table (make-hash-table :test #'equal))
        (iterator (%call :headers (%call :request request "Headers") "GetEnumerator")))
    (loop while (%call :header-enumerator iterator "MoveNext")
          do (let ((pair (%call :header-enumerator iterator "Current")))
               (setf (gethash (string-downcase (%call :header-pair pair "Key")) table)
                     (%call :string-values (%call :header-pair pair "Value") "ToString"))))
    table))

(defvar *keywords*
  (mapcar (lambda (name) (cons name (intern name :keyword)))
          '("GET" "POST" "HEAD" "PUT" "DELETE" "OPTIONS" "PATCH"
            "HTTP/1.1" "HTTP/1.0" "HTTP/2" "HTTP/3")))

(defun %keyword (string)
  (or (cdr (assoc string *keywords* :test #'string=))
      (intern (string-upcase string) :keyword)))

(defun %then (task continuation)
  "A task for CONTINUATION's task, called once TASK has finished. A task already
finished calls it at once, on this thread. No thread waits for TASK."
  (if (%call :task task "IsCompletedSuccessfully")
      (funcall continuation)
      (dotcl:async
        (dotcl:await task)
        (dotcl:await (funcall continuation)))))

(defun %settle (task finish)
  "Call FINISH once TASK has finished, however it finished; an error in TASK is
a client going away and is not reported. Returns no task."
  (if (%call :task task "IsCompletedSuccessfully")
      (funcall finish)
      (dotcl:async
        (handler-case (dotcl:await task)
          (error () nil))
        (funcall finish)))
  nil)

(defun %synchronous-body (context)
  (let ((feature (%call :features (%call :context context "Features") "Item"
                        (:type (dotnet:resolve-type
                                "Microsoft.AspNetCore.Http.Features.IHttpBodyControlFeature")))))
    (when feature
      (setf (dotnet:invoke feature "AllowSynchronousIO") t)))
  (dotnet:to-stream (%call :request (%call :context context "Request") "Body")
                    :binary t))

(defun %can-have-body (context)
  "False when Kestrel knows the request has no body."
  (let ((feature (%call :features (%call :context context "Features") "Item"
                        (:type *body-detection*))))
    (or (null feature)
        (%call :body-detection feature "CanHaveBody"))))

(defun %read-body (context continuation)
  "Call CONTINUATION with the request body as a CL input stream over bytes in
memory, once all of it has arrived, and return its task."
  (if (%can-have-body context)
      (let ((buffer (dotnet:new "System.IO.MemoryStream")))
        (%then (%call :stream (%call :request (%call :context context "Request") "Body")
                      "CopyToAsync" (:stream buffer))
               (lambda ()
                 (%call :memory-stream buffer "set_Position" (:long 0))
                 (funcall continuation (dotnet:to-stream buffer :binary t)))))
      (funcall continuation (dotnet:to-stream *no-body* :binary t))))

(defun %environment (context raw-body)
  "The request as a Lack environment plist."
  (let* ((request (%call :context context "Request"))
         (connection (%call :context context "Connection"))
         (headers (%call :request request "Headers"))
         (host (%call :request request "Host"))
         (query (%call :query (%call :request request "QueryString") "Value"))
         (raw-target (%call :request-feature
                            (%call :features (%call :context context "Features") "Item"
                                   (:type *request-feature*))
                            "RawTarget"))
         (length (%header-value headers "content-length"))
         (address (%call :connection connection "RemoteIpAddress")))
    (list :request-method (%keyword (%call :request request "Method"))
          :script-name ""
          :path-info (or (%call :path (%call :request request "Path") "Value") "")
          :query-string (when (and query (> (length query) 1))
                          (subseq query 1))
          :request-uri raw-target
          :server-protocol (%keyword (%call :request request "Protocol"))
          :url-scheme (string-downcase (%call :request request "Scheme"))
          :server-name (or (%call :host host "Host") "")
          :server-port (or (%call :host host "Port")
                           (%call :connection connection "LocalPort"))
          :remote-addr (if address (%call :address address "ToString") "")
          :remote-port (%call :connection connection "RemotePort")
          :content-type (%header-value headers "content-type")
          :content-length (when length (parse-integer length :junk-allowed t))
          :headers (%request-headers request)
          :raw-body raw-body
          :clack.streaming t)))

(defun %write-headers (response status headers)
  "Set STATUS and apply a Lack header plist. A name given twice is sent twice,
as Set-Cookie needs."
  (%call :response response "set_StatusCode" (:int status))
  (let ((collection (dotnet:cast (%call :response response "Headers") *header-dictionary*)))
    (loop for (name value) on headers by #'cddr
          for text = (string-downcase (string name))
          when value
            do (if (string= text "content-type")
                   (%call :response response "set_ContentType" (:string (princ-to-string value)))
                   (dotnet:static "Microsoft.AspNetCore.Http.HeaderDictionaryExtensions"
                                  "Append" collection text (princ-to-string value))))))

(defun %octets (vector start end)
  (let ((end (or end (length vector))))
    (if (and (typep vector '(simple-array (unsigned-byte 8) (*)))
             (= start 0) (= end (length vector)))
        vector
        (coerce (subseq vector start end) '(simple-array (unsigned-byte 8) (*))))))

(defun %write-chunk (response chunk &key (start 0) end)
  "Start writing a string (as UTF-8) or a vector of octets; return the task.
HttpResponse.WriteAsync is an extension method, named where it is defined:
found through the response it is a search at every call."
  (etypecase chunk
    (null *completed-task*)
    (string
     (dotnet:static "Microsoft.AspNetCore.Http.HttpResponseWritingExtensions" "WriteAsync"
                    response (if (or (plusp start) end) (subseq chunk start end) chunk)
                    *no-cancellation*))
    ((vector (unsigned-byte 8))
     (let ((octets (%octets chunk start end)))
       (dotnet:invoke (%call :response response "Body") "WriteAsync"
                      octets 0 (length octets))))))

(defun %write-each (response next)
  "Write the chunks NEXT returns, until it returns NIL; return the task."
  (loop for chunk = (funcall next)
        while chunk
        do (let ((task (%write-chunk response chunk)))
             (unless (%call :task task "IsCompletedSuccessfully")
               (return-from %write-each
                 (%then task (lambda () (%write-each response next)))))))
  *completed-task*)

(defun %write-body (response body)
  "Send BODY: a list of strings or octet vectors, a single string, an octet
vector, or a pathname. Returns the task."
  (etypecase body
    (null *completed-task*)
    (pathname
     (dotnet:load-assembly "Microsoft.AspNetCore.Http.Extensions")
     (dotnet:static "Microsoft.AspNetCore.Http.SendFileResponseExtensions"
                    "SendFileAsync" response (namestring (truename body))))
    (cons (%write-each response (lambda () (pop body))))
    ((or string (vector (unsigned-byte 8)))
     (%write-chunk response body))))

(defun %report (condition)
  (ignore-errors
   (format *error-output* "~&clack-handler-kestrel: ~a~%" condition)
   (finish-output *error-output*)))

(defun %fail (response condition debug)
  "Answer 500 unless the response has already started going out. Returns the task."
  (%report condition)
  (or (and (not (%call :response response "HasStarted"))
           (ignore-errors
            (%write-headers response 500 (list :content-type "text/plain; charset=utf-8"))
            (%write-chunk response (if debug
                                       (format nil "Internal Server Error~%~%~a~%" condition)
                                       "Internal Server Error"))))
      *completed-task*))

(defun %respond (response result)
  "Send (status headers body); return the task."
  (destructuring-bind (status headers &optional body) result
    (%write-headers response status headers)
    (let ((task (%write-body response body)))
      (if (%call :task task "IsCompletedSuccessfully")
          task
          (dotcl:async
            (handler-case (dotcl:await task)
              (error () nil)))))))

(defun %respond-later (response function)
  "Call FUNCTION, which is given the responder; return a task completed when the
response is: by the responder when it is given a body, by the writer's :close
when it is not."
  (let* ((done (dotnet:new "System.Threading.Tasks.TaskCompletionSource"))
         (task (dotnet:invoke done "Task")))
    (flet ((finish () (dotnet:invoke done "TrySetResult")))
      (flet ((respond (result)
               (destructuring-bind (status headers &optional (body nil body-p)) result
                 (%write-headers response status headers)
                 (cond
                   (body-p
                    (%settle (%write-body response body) #'finish))
                   (t
                    (lambda (chunk &key (start 0) end close)
                      (let ((written nil))
                        (unwind-protect
                             (progn
                               (dotnet:await (%write-chunk response chunk :start start :end end))
                               (dotnet:await (dotnet:invoke (%call :response response "Body")
                                                            "FlushAsync"))
                               (setf written t))
                          (when (or close (not written)) (finish))))))))))
        (funcall function #'respond)))
    task))

(defun %serve (context application debug raw-body)
  "Call APPLICATION on the request and send what it returns. Returns the task
Kestrel waits on before it ends the response."
  (let ((response (%call :context context "Response")))
    (handler-case
        (let ((result (funcall application (%environment context raw-body))))
          (etypecase result
            (list (%respond response result))
            (function (%respond-later response result))))
      (error (condition)
        (%fail response condition debug)))))

(defun %handle (context application allow-synchronous-io debug)
  (if allow-synchronous-io
      (%serve context application debug (%synchronous-body context))
      (%read-body context
                  (lambda (raw-body) (%serve context application debug raw-body)))))

(defun %seconds (seconds)
  (dotnet:static "System.TimeSpan" "FromSeconds" (float seconds 1d0)))

(defun %configure-limits (builder limits)
  "Set Kestrel's Limits from LIMITS, a plist of property names and values."
  (when limits
    (dotnet:static "Microsoft.AspNetCore.Hosting.WebHostBuilderKestrelExtensions"
                   "ConfigureKestrel" (dotnet:invoke builder "WebHost")
                   (dotnet:make-delegate
                    "System.Action`1[[Microsoft.AspNetCore.Server.Kestrel.Core.KestrelServerOptions, Microsoft.AspNetCore.Server.Kestrel.Core]]"
                    (lambda (options)
                      (let ((target (dotnet:invoke options "Limits")))
                        (loop for (name value) on limits by #'cddr
                              do (setf (dotnet:invoke target name) value))))))))

(defun %url (address port)
  (format nil "http://~a:~a"
          (if (and (find #\: address) (char/= (char address 0) #\[))
              (format nil "[~a]" address)
              address)
          port))

(defun %make-server (app &key (port 5000) (address "127.0.0.1") debug allow-synchronous-io
                    (max-request-headers-total-size nil headers-size-p)
                    (max-request-body-size nil body-size-p)
                    (min-request-body-data-rate nil body-rate-p)
                    (request-headers-timeout nil headers-timeout-p)
                    (max-concurrent-connections nil connections-p)
                    &allow-other-keys)
  "A Kestrel server for APP, configured but not yet started."
  (let ((builder (dotnet:static "Microsoft.AspNetCore.Builder.WebApplication" "CreateBuilder")))
    (dotnet:static "Microsoft.Extensions.Logging.LoggingBuilderExtensions"
                   "ClearProviders" (dotnet:invoke builder "Logging"))
    (%configure-limits
     builder
     (append
      (when headers-size-p
        (list "MaxRequestHeadersTotalSize" max-request-headers-total-size))
      (when body-size-p
        (list "MaxRequestBodySize" max-request-body-size))
      (when body-rate-p
        (list "MinRequestBodyDataRate"
              (when min-request-body-data-rate
                (destructuring-bind (rate grace) min-request-body-data-rate
                  (dotnet:new "Microsoft.AspNetCore.Server.Kestrel.Core.MinDataRate"
                              (float rate 1d0) (%seconds grace))))))
      (when headers-timeout-p
        (list "RequestHeadersTimeout" (%seconds request-headers-timeout)))
      (when connections-p
        (list "MaxConcurrentConnections" max-concurrent-connections))))
    (let ((server (dotnet:invoke builder "Build")))
      (dotnet:invoke (dotnet:invoke server "Urls") "Add" (%url address port))
      (dotnet:static "Microsoft.AspNetCore.Builder.RunExtensions" "Run" server
                     (dotnet:make-delegate "Microsoft.AspNetCore.Http.RequestDelegate"
                                           (lambda (context)
                                             (%handle context app allow-synchronous-io debug))))
      server)))

(defun start (app &rest args)
  "Serve the Lack application APP and return the server, which STOP takes.
Returns once the server is listening; requests are served on .NET thread pool
threads.

Keyword arguments: PORT (default 5000), ADDRESS (default \"127.0.0.1\"), DEBUG,
ALLOW-SYNCHRONOUS-IO, and Kestrel's limits, each left at Kestrel's default when
not given: MAX-REQUEST-HEADERS-TOTAL-SIZE and MAX-REQUEST-BODY-SIZE in bytes,
REQUEST-HEADERS-TIMEOUT in seconds, MIN-REQUEST-BODY-DATA-RATE as a list
(bytes-per-second grace-period-seconds), MAX-CONCURRENT-CONNECTIONS. NIL for
MAX-REQUEST-BODY-SIZE, MIN-REQUEST-BODY-DATA-RATE or MAX-CONCURRENT-CONNECTIONS
removes that limit.

On an error in APP the client gets a 500 and the error is printed to
*ERROR-OUTPUT*; with DEBUG the response body also carries the error message."
  (let ((server (apply #'%make-server app args)))
    (dotnet:await (dotnet:invoke server "StartAsync"))
    server))

(defun stop (server)
  "Stop SERVER and wait for it to finish. Stopping a stopped server does nothing."
  (dotnet:await (dotnet:invoke server "StopAsync"))
  t)

(defun run (app &rest args)
  "The Clack entry point, taking the arguments START takes: start the server,
block until it stops, and return it. Unwinding out of the wait stops the
server, which is how CLACK:STOP (by destroying the thread RUN is on) ends it;
STOP from another thread also ends the wait."
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
