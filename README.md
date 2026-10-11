# clack-handler-kestrel

A [Clack](https://github.com/fukamachi/clack) handler for
[dotcl](https://github.com/dotcl/dotcl), serving on ASP.NET Core's Kestrel.

    (clack:clackup app :server :kestrel :port 5000)

It runs only on dotcl, and needs the ASP.NET Core shared framework
(`Microsoft.AspNetCore.App`), which the .NET SDK and the ASP.NET Core runtime
both include.

## Loading

Load the system before calling `clackup`:

    (ql:quickload '("clack-handler-kestrel" "clack"))

Newer Clack finds the handler by itself from `:server :kestrel`. The Clack in
the current Quicklisp release does not find any handler that is not loaded yet,
so loading it first works with both.

## Through Clack

`clack:clackup` accepts the usual arguments. Those this handler reads:

- `:port` (default 5000) and `:address` (default `"127.0.0.1"`).
- `:debug`: when the application signals an error, the client gets a 500 and
  the error is printed to `*error-output*` either way. With `:debug t` (Clack's
  default) the 500 response body also carries the error message. The debugger
  is never entered: the request runs on a .NET thread pool thread with nobody
  to answer it.
- `:allow-synchronous-io`: see "Request bodies" below.

`clack:stop` stops the server and releases the port.

## Without Clack

The package `clack.handler.kestrel` exports three functions, all taking a Lack
application (a function of the environment plist):

- `(start app &key port address debug allow-synchronous-io)` starts serving and
  returns the server once it is listening.
- `(stop server)` stops it and waits until it has stopped. Stopping a stopped
  server does nothing.
- `(run app &rest args)` is what Clack calls: `start` with the same arguments,
  then it blocks until the server stops. Unwinding out of `run` (Clack stops a
  server by destroying the thread `run` is on) stops the server, and so does
  `stop` from another thread.

## What an application gets and may return

The environment has the keys Lack applications expect: `:request-method`,
`:script-name`, `:path-info` (decoded), `:query-string`, `:request-uri` (as
sent), `:server-name`, `:server-port`, `:server-protocol`, `:url-scheme`,
`:remote-addr`, `:remote-port`, `:content-type`, `:content-length`, `:headers`
(a hash table keyed by lower-case name) and `:raw-body`, plus
`:clack.streaming t`.

A response is `(status headers body)`, where body is a list of strings or octet
vectors, a single string, an octet vector, or a pathname (sent as a file).
Strings go out as UTF-8. A header named more than once in `headers` is sent
more than once, as `Set-Cookie` needs.

A delayed response works too: the application returns a function of one
argument, the responder. Calling the responder with `(status headers body)`
sends the response. Calling it with `(status headers)` returns a writer,
`(lambda (data &key start end close))`, that sends each piece as it is written
(chunked) and ends the response when called with `:close t`. The writer may be
called from another thread after the application has returned.

## Request bodies

Kestrel refuses synchronous reads and writes on its own streams by default,
because a thread waiting on a socket holds a thread pool thread. A Lack
application reads `:raw-body` synchronously, so the handler reads the whole
request body into memory before calling the application, and `:raw-body` is a
stream over those bytes. Kestrel limits a request body to 30,000,000 bytes by
default.

Pass `:allow-synchronous-io t` to hand the application Kestrel's own request
stream instead, without reading it first; an application taking a large upload
as a stream will want that.

## Tests

From the repository root, with Quicklisp available to dotcl:

    dotcl test/run.lisp < /dev/null

It starts servers on port 8086 (set `KESTREL_TEST_PORT` to change it) and checks
requests, responses, streaming, large bodies, `clack:stop`, and Lack middleware
(`lack-middleware-static` and a hand-written one) through `clack:clackup`.

## License

MIT. See `LICENSE`.
