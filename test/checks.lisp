;;; The checks themselves; test/run.lisp loads the systems first.

(defpackage :clack-handler-kestrel-test
  (:use :cl))
(in-package :clack-handler-kestrel-test)

(defvar *port* (let ((env (dotcl:getenv "KESTREL_TEST_PORT")))
                 (if env (parse-integer env) 8086)))
(defvar *checks* 0)
(defvar *failures* 0)

(defun check (label expected actual)
  (incf *checks*)
  (cond ((equal expected actual) (format t "~&ok    ~a~%" label))
        (t (incf *failures*)
           (format t "~&FAIL  ~a~%  expected ~s~%  got      ~s~%" label expected actual)))
  (finish-output))

(defvar *static-root* (merge-pathnames "static/" *load-truename*))

(defvar *big* (make-string (* 5 1024 1024) :initial-element #\x))

(defun read-raw-body (env)
  (let* ((n (or (getf env :content-length) 0))
         (bytes (make-array n :element-type '(unsigned-byte 8))))
    (read-sequence bytes (getf env :raw-body))
    bytes))

(defun app (env)
  (let ((path (getf env :path-info)))
    (cond
      ((string= path "/env")
       (list 200 (list :content-type "text/plain")
             (list (format nil "~a|~a|~a|~a|~a|~a|~a"
                           (getf env :request-method)
                           (getf env :path-info)
                           (getf env :query-string)
                           (getf env :server-protocol)
                           (getf env :url-scheme)
                           (getf env :request-uri)
                           (gethash "x-check" (getf env :headers))))))
      ((string= path "/echo")
       (list 200 (list :content-type "application/octet-stream") (read-raw-body env)))
      ((string= path "/missing")
       (list 404 (list :content-type "text/plain" :x-reason "gone") (list "nope")))
      ((string= path "/cookies")
       (list 200 (list :set-cookie "a=1" :set-cookie "b=2") (list "two cookies")))
      ((string= path "/string") (list 200 (list :content-type "text/plain") "plain"))
      ((string= path "/bytes")
       (list 200 '() (map '(vector (unsigned-byte 8)) #'char-code "octets")))
      ((string= path "/big") (list 200 (list :content-type "text/plain") (list *big*)))
      ((string= path "/delayed")
       (lambda (responder) (funcall responder (list 200 '() (list "delayed")))))
      ((string= path "/stream")
       (lambda (responder)
         (let ((writer (funcall responder (list 200 (list :content-type "text/plain")))))
           (funcall writer "one ")
           (sleep 0.1)
           (funcall writer (map '(vector (unsigned-byte 8)) #'char-code "two "))
           (sleep 0.1)
           (funcall writer "three" :close t))))
      ((string= path "/meta")
       (let ((body (getf env :raw-body)))
         (list 200 (list :content-type "text/plain")
               (list (format nil "~a|~a|~a|~a|~a|~a"
                             (getf env :server-name)
                             (getf env :content-length)
                             (getf env :content-type)
                             (read-byte body nil :eof)
                             (stream-element-type body)
                             (getf env :query-string))))))
      ((string= path "/lines")
       (list 200 (list :content-type "text/plain")
             (list (format nil "line 1~%line 2~%") (format nil "line 3~c~%" #\Return))))
      ((string= path "/error") (error "deliberate"))
      (t (list 200 (list :content-type "text/plain") (list "one " "two " "three"))))))

;;; The client.

(defvar *client* (dotnet:new "System.Net.Http.HttpClient"))

(defun url (path) (format nil "http://127.0.0.1:~a~a" *port* path))

(defun request (method path &key body headers)
  (let ((message (dotnet:new "System.Net.Http.HttpRequestMessage"
                             (dotnet:new "System.Net.Http.HttpMethod" method)
                             (url path))))
    (loop for (name value) on headers by #'cddr
          do (dotnet:invoke (dotnet:invoke message "Headers") "Add" name value))
    (when body
      (setf (dotnet:invoke message "Content")
            (if (stringp body)
                (dotnet:new "System.Net.Http.StringContent" body)
                (dotnet:new "System.Net.Http.ByteArrayContent" body))))
    (dotnet:await (dotnet:invoke *client* "SendAsync" message))))

(defun fetch (path) (request "GET" path))

(defun response-text (response)
  (dotnet:await (dotnet:invoke (dotnet:invoke response "Content") "ReadAsStringAsync")))

(defun response-bytes (response)
  (let* ((array (dotnet:await (dotnet:invoke (dotnet:invoke response "Content")
                                             "ReadAsByteArrayAsync")))
         (stream (dotnet:to-stream (dotnet:new "System.IO.MemoryStream" array) :binary t))
         (bytes (make-array (dotnet:invoke array "Length") :element-type '(unsigned-byte 8))))
    (read-sequence bytes stream)
    bytes))

(defun status (response)
  (dotnet:invoke (dotnet:invoke response "StatusCode") "GetHashCode"))

(defun header-values (response name)
  "Every value of header NAME, from the response or its content headers."
  (flet ((try (headers)
           (handler-case
               (let ((iterator (dotnet:invoke (dotnet:invoke headers "GetValues" name)
                                              "GetEnumerator")))
                 (loop while (dotnet:invoke iterator "MoveNext")
                       collect (dotnet:invoke iterator "Current")))
             (error () nil))))
    (or (try (dotnet:invoke response "Headers"))
        (try (dotnet:invoke (dotnet:invoke response "Content") "Headers")))))

(defun header (response name) (first (header-values response name)))

(defun refused-p ()
  (handler-case (progn (fetch "/") nil)
    (error () t)))

;;; Through clack:clackup.

(check "find-handler" (find-package "CLACK.HANDLER.KESTREL")
       (clack.util:find-handler :kestrel))

(defvar *handle* (clack:clackup #'app :server :kestrel :port *port* :silent t))
(sleep 1)

(let ((r (fetch "/")))
  (check "GET: body as a list of strings" "one two three" (response-text r))
  (check "GET: status 200" 200 (status r))
  (check "GET: content-type" "text/plain" (header r "Content-Type")))

(check "GET: body as a single string" "plain" (response-text (fetch "/string")))
(check "GET: body as an octet vector" "octets" (response-text (fetch "/bytes")))

(let ((r (request "GET" "/env?a=1&b=%20" :headers (list "X-Check" "seen"))))
  (check "request as the application sees it"
         "GET|/env|a=1&b=%20|HTTP/1.1|http|/env?a=1&b=%20|seen"
         (response-text r)))

(let ((r (fetch "/missing")))
  (check "status from the application" 404 (status r))
  (check "header from the application" "gone" (header r "X-Reason")))

(check "a header given twice is sent twice" '("a=1" "b=2")
       (header-values (fetch "/cookies") "Set-Cookie"))

(check "POST: request body" "body through raw-body"
       (response-text (request "POST" "/echo" :body "body through raw-body")))

(let* ((size (* 2 1024 1024))
       (sent (let ((v (make-array size :element-type '(unsigned-byte 8))))
               (dotimes (i size v) (setf (aref v i) (mod (* i 7) 256)))))
       (got (response-bytes (request "POST" "/echo" :body sent))))
  (check "POST: 2 MB request body comes back intact"
         (list size t)
         (list (length got) (every #'= sent got))))

(let ((text (response-text (fetch "/big"))))
  (check "GET: 5 MB response body" (list (length *big*) t)
         (list (length text) (string= text *big*))))

(check "delayed response" "delayed" (response-text (fetch "/delayed")))

(let ((r (fetch "/stream")))
  (check "streaming response through the writer" "one two three" (response-text r))
  (check "streaming response is chunked" "chunked"
         (string-downcase (or (header r "Transfer-Encoding") ""))))

(let ((r (let ((*error-output* (make-broadcast-stream))) (fetch "/error"))))
  (check "an error in the application is a 500" 500 (status r)))

(check "request without a body"
       "127.0.0.1|NIL|NIL|EOF|(UNSIGNED-BYTE 8)|NIL"
       (response-text (fetch "/meta")))

(check "request with a body"
       "127.0.0.1|3|text/plain; charset=utf-8|97|(UNSIGNED-BYTE 8)|NIL"
       (response-text (request "POST" "/meta" :body "abc")))

(check "newlines in a response body are kept"
       (format nil "line 1~%line 2~%line 3~c~%" #\Return)
       (response-text (fetch "/lines")))

;;; Requests whose bodies have not arrived hold no thread: with many of them
;;; open, another request is still served at once.
(defun ascii (string)
  (dotnet:invoke (dotnet:static "System.Text.Encoding" "ASCII") "GetBytes" string))

(let ((stalled
        (loop repeat 64
              collect (let ((client (dotnet:new "System.Net.Sockets.TcpClient" "127.0.0.1" *port*)))
                        (dotnet:invoke (dotnet:invoke client "GetStream") "Write"
                                       (ascii (format nil "POST /echo HTTP/1.1~c~cHost: x~c~cContent-Length: 1000~c~c~c~c"
                                                      #\Return #\Newline #\Return #\Newline
                                                      #\Return #\Newline #\Return #\Newline)))
                        client)))
      (client (dotnet:new "System.Net.Http.HttpClient")))
  (sleep 1)
  (setf (dotnet:invoke client "Timeout") (dotnet:static "System.TimeSpan" "FromSeconds" 3d0))
  (check "served while 64 request bodies are stalled"
         "one two three"
         (handler-case (response-text (dotnet:await (dotnet:invoke client "GetAsync" (url "/"))))
           (error (e) (princ-to-string e))))
  (mapc (lambda (c) (dotnet:invoke c "Dispose")) stalled))

(check "clack:stop" t (clack:stop *handle*))
(sleep 1)
(check "nothing listens after clack:stop" t (refused-p))

;;; Lack middleware, through clackup.

(defvar *lack-app*
  (lack:builder
   (:static :path "/static/" :root *static-root*)
   (lambda (app)
     (lambda (env)
       (let ((response (funcall app env)))
         (list (first response)
               (append (second response) (list :x-middleware "ran"))
               (third response)))))
   (lambda (env)
     (list 200 (list :content-type "text/plain")
           (list (format nil "lack ~a ~a" (getf env :request-method) (getf env :path-info)))))))

(setf *handle* (clack:clackup *lack-app* :server :kestrel :port *port* :silent t))
(sleep 1)

(let ((r (fetch "/hello")))
  (check "lack:builder application" "lack GET /hello" (response-text r))
  (check "lack middleware" "ran" (header r "X-Middleware")))

(let ((r (fetch "/static/hello.txt")))
  (check "lack-middleware-static: body" (format nil "static file~%") (response-text r))
  (check "lack-middleware-static: content-type" "text/plain; charset=utf-8"
         (header r "Content-Type")))

(check "lack-middleware-static: missing file" 404 (status (fetch "/static/none.txt")))

(clack:stop *handle*)
(sleep 1)

;;; Without Clack: start and stop.

(defvar *server* (clack.handler.kestrel:start #'app :port *port*))
(check "start without clack" "plain" (response-text (fetch "/string")))
(check "stop" t (clack.handler.kestrel:stop *server*))
(check "stop twice" t (clack.handler.kestrel:stop *server*))
(check "nothing listens after stop" t (refused-p))

;;; Kestrel's limits, set through start.

(setf *server* (clack.handler.kestrel:start #'app :port *port*
                                            :max-request-body-size 10
                                            :max-request-headers-total-size 2048
                                            :request-headers-timeout 5
                                            :min-request-body-data-rate '(100 3)
                                            :max-concurrent-connections 100))
(check "body under max-request-body-size" "short"
       (response-text (request "POST" "/echo" :body "short")))
(check "body over max-request-body-size" 413
       (status (request "POST" "/echo" :body "longer than ten bytes")))
(check "headers over max-request-headers-total-size" 431
       (status (request "GET" "/" :headers (list "X-Big" (make-string 4000 :initial-element #\a)))))
(clack.handler.kestrel:stop *server*)

(setf *server* (clack.handler.kestrel:start #'app :port *port*
                                            :max-request-body-size nil
                                            :min-request-body-data-rate nil
                                            :max-concurrent-connections nil))
(check "limits removed with NIL" "plain" (response-text (fetch "/string")))
(clack.handler.kestrel:stop *server*)

(format t "~&~a checks, ~a failed~%" *checks* *failures*)
(format t "~&~a~%" (if (zerop *failures*) "KESTREL-OK" "KESTREL-FAILED"))
(finish-output)
(dotcl:quit (if (zerop *failures*) 0 1))
