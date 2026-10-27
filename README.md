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
- Kestrel's limits, see "Limits" below.

`clack:stop` stops the server and releases the port.

Pass `:debug nil` for anything but local work. Clack's own `:debug t` prints a
backtrace and the request to `*error-output*` when the application signals an
error, and this handler's 500 response then carries the error message.

## Limits

Five of Kestrel's limits can be set from `clackup` (or from `start` and `run`).
One not given keeps Kestrel's default.

    (clack:clackup app :server :kestrel :port 5000
                       :max-request-headers-total-size 32768 ; bytes
                       :max-request-body-size 30000000       ; bytes, NIL for none
                       :min-request-body-data-rate '(240 5)  ; bytes per second, grace seconds; NIL for none
                       :request-headers-timeout 30           ; seconds
                       :max-concurrent-connections nil)      ; NIL for none

A request over the headers limit is answered with 431, over the body limit with
413. A client that sends its body slower than the data rate, after the grace
period, is disconnected, as is one that has not finished its headers within
the timeout.

## Without Clack

The package `clack.handler.kestrel` exports three functions, all taking a Lack
application (a function of the environment plist):

- `(start app &key port address debug allow-synchronous-io ...)` starts serving
  and returns the server once it is listening; the limits above are keywords
  too.
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
stream over those bytes. The read is asynchronous and holds no thread while the
bytes are on their way, so many clients sending slowly do not stop other
requests from being served; the response body is written the same way. A
request that cannot have a body (a GET, say) gets an empty stream and nothing
is buffered. Kestrel limits a request body to 30,000,000 bytes by default.

Pass `:allow-synchronous-io t` to hand the application Kestrel's own request
stream instead, without reading it first; an application taking a large upload
as a stream will want that.

## Behaviour under bad clients

Checked with a script that opens slow, oversized and broken connections, on
dotcl 0.1.35. The server stayed up and kept answering other requests in each
case:

- 200 clients that open a request and never finish it, or send a body one byte
  at a time (they are cut off by the header timeout and the minimum data rate);
- a 1 MB header value, 20,000 headers, 100 MB bodies with and without a
  length (refused by the limits above);
- malformed request lines, bad versions, bad chunk sizes, conflicting
  Content-Length headers (answered 400);
- connections cut or reset in the middle of a request or before the response;
- an application that signals an error, 1,000 times in a row (each a 500).

Resident memory afterwards was about 250 MB, from 230 MB before the first
case. This is a description of what was tried, not a guarantee.

## Throughput and the garbage collector

.NET's workstation garbage collector is the default. For a busy server,
setting the environment variable `DOTNET_gcServer=1` before starting dotcl
selects the server collector. On one Linux x86_64 laptop it gave about 21% more
requests per second on a small plain-text response, and a lower p99 latency;
it also uses more memory. The default is not changed here: try it on your own
load and decide.

## Logging

Kestrel's and ASP.NET Core's own log output is turned off. What is left is
what this handler prints to `*error-output*` when the application signals an
error (one line, `clack-handler-kestrel: <condition>`) and what Clack prints
with `:debug t`. To silence them, pass `:debug nil` and bind or redirect
`*error-output*`, or start dotcl with `2>/dev/null`.

## Tests

From the repository root, with Quicklisp available to dotcl:

    dotcl test/run.lisp < /dev/null

It starts servers on port 8086 (set `KESTREL_TEST_PORT` to change it) and checks
requests with and without a body, responses and newlines in them, streaming,
large bodies, that another request is still served while 64 clients have sent
headers and no body, the limits, `clack:stop`, and Lack middleware
(`lack-middleware-static` and a hand-written one) through `clack:clackup`.

## License

MIT. See `LICENSE`.
