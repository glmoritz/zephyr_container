# net: http_client: complete keep-alive response discarded as -EBADMSG when trailing bytes follow

## Summary
`http_client_req()` returns `-EBADMSG` and logs `HTTP parsing error, 30` for a **fully received,
well-formed** HTTP/1.1 response when the receive buffer also contains one or more **trailing bytes
after** the complete response. The complete, correctly-parsed response is thrown away.

## Affected
- Zephyr `main` / v4.4.x-dev (repro on commit `fbfc5f19636d`, VERSION 4.4.99).
- `subsys/net/lib/http/http_client.c`, function `http_wait_data()`.
- Introduced/exposed by the recv-loop rework in `4a85e470617`
  ("net: http: client: Notify application about unprocessed data", 2025-04-29), which changed the
  loop to parse the **whole** accumulated buffer from the base on every iteration and to stop
  ignoring the `http_parser_execute()` errno.

## Root cause
For a keep-alive response (HTTP/1.1, no `Connection: close`), once the body completes the parser
fires `on_message_complete` and `NEW_MESSAGE()` resets it to `s_start_res` to expect the *next*
pipelined response. If the same `http_parser_execute()` call then sees trailing bytes that are not
the start of `HTTP/` (or CR/LF), it sets `HPE_INVALID_CONSTANT` (errno 30) — `http_parser.c`
`s_start_res` case. In `http_wait_data()` the parser errno is checked **before** `message_complete`:

```c
processed = http_parser_execute(&parser, &settings, recv_buf, offset);
...
if (parser.http_errno != HPE_OK) {        /* checked first */
    LOG_ERR("HTTP parsing error, %d", parser.http_errno);
    ret = -EBADMSG; goto error;
}
...
if (req->internal.response.message_complete) { http_report_complete(req); }  /* never reached */
```

So a completed response is discarded because of bytes that belong to the *caller* (which the same
rework intended to expose via `data_len`).

## Reproduction (native_sim, deterministic)
Added `tests/net/lib/http_client` suite `http_client_trailing_byte` (see `test.patch`): a loopback
server sends, in one `send()`, a complete `Content-Length`-delimited keep-alive `409` response plus
one stray trailing byte. `http_client_req()` returns `-EBADMSG` instead of status 409.

Instrumented `http_wait_data()` at the error point confirms the mechanism:
```
INSTRUMENT: http_errno=30 offset=79 processed=78 msg_complete=1
```
`processed=78` = the entire response consumed; `msg_complete=1` = response fully parsed;
`http_errno=30` = `HPE_INVALID_CONSTANT` from the 1 trailing byte (`offset=79`).

## Real-world impact
An ESP32-S3 device using `http_client` over TLS could not register: the server replied `409
Conflict` ("device already registered", a perfectly valid keep-alive response) and the client
returned `-EBADMSG` (`-77` on newlib) with `net_http_client: HTTP parsing error, 30`, so the
application never saw the 409 and retried forever.

## Fix (`fix.patch`)
Treat a parser errno as fatal only if the message did **not** complete:
```c
if (req->internal.parser.http_errno != HPE_OK &&
    !req->internal.response.message_complete) {
    LOG_ERR("HTTP parsing error, %d", req->internal.parser.http_errno);
    ret = -EBADMSG; goto error;
}
```
After completion the response is delivered (`http_report_complete`) and the unconsumed trailing
bytes remain available to the caller via `data_len` (the rework's intended contract).

## Verification
- New `http_client_trailing_byte` test: FAIL before, PASS after.
- All 9 existing `http_client` tests + `http_client_chunked_te` still PASS (no regression).
