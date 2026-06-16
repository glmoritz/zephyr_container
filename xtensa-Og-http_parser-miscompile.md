# Bug: Zephyr `http_parser.c` miscompiled at `-Og` on Espressif xtensa GCC

**Severity:** high (silently breaks all multi-digit `Content-Length` HTTP responses)
**Affected:** ESP32-S3 (xtensa), Zephyr v4.4.0-dev, Espressif xtensa GCC, `CONFIG_DEBUG_OPTIMIZATIONS=y` (`-Og`)
**Not affected:** `-Os` (`CONFIG_SIZE_OPTIMIZATIONS`), `-O0` (`CONFIG_NO_OPTIMIZATIONS`), x86 native_sim at any level.

## Symptom
Any HTTP response with a multi-digit `Content-Length` fails: `net_http_client: HTTP parsing
error, 30` (`HPE_INVALID_CONSTANT`) → `http_client_req` returns `-EBADMSG` (`-77`). On our device
this broke `POST /auth/devices/register` (and every other Content-Length response), so the device
could never register. Single-digit lengths "work" by luck (see below).

## Root cause
At `-Og` the xtensa compiler miscompiles `subsys/net/lib/http/http_parser.c`. In
`header_states()`:

```c
enum header_states h_state = *header_state;   /* ~line 529 */
switch (h_state) { ... }
```

`*header_state` yields garbage (a stack-address-shaped value) even though the caller's
`parser->header_state` is correct (`13 == h_content_length`). The `switch` then falls to
`default`, so the **Content-Length value accumulator** (digits 2..N, the `case h_content_length`
that does `t = content_length*10 + (ch-'0')`) never runs. Only the first digit is registered in
`s_header_value_start` (`content_length = ch - '0'`):

- `Content-Length: 182` → parser frames the body as **1** byte
- `Content-Length: 70`  → **7** bytes

The body "completes" after that many bytes; the next body byte is parsed as the start of a new
(keep-alive) message, isn't `H`, → `HPE_INVALID_CONSTANT` (errno 30) → `-EBADMSG`.

## Evidence
- Device (`-Og`): `recv=318 proc=137 mc=1 errno=30 cl=182 bproc=1` — parser stopped after 1 body byte.
- Loopback ztest with the *identical bytes* at `-Os`: `proc=318 bproc=182 errno=0` — correct.
- gdb on device: `parser->header_state == 13` (struct intact) but local `h_state` garbage /
  "optimized_out"; `header_states()` is entered for the 2nd digit but the `h_content_length` case
  is never reached (falls to `default`).
- Ruled out: char-signedness (`-funsigned-char` on x86 still correct), stack overflow (struct
  field intact), TLS, the response bytes themselves.

## Repro
`tests/net/lib/http_client`: have a loopback server send a complete `Content-Length: 182` 201
response (headers + 182-byte body) in one `send`; assert the callback accumulates 182 bytes.
Passes at `-Os`/`-O0`; fails (errno 30 / `-EBADMSG`) when built for xtensa at `-Og`.

## Fix / workaround
Do not build this target at `-Og`. Use `-Os` (`CONFIG_SIZE_OPTIMIZATIONS=y`) — that is what
`projects/hello_eink/debug.conf` now pins, with a comment. `-Os` still debugs adequately
(FRAME_POINTER + THREAD_INFO kept). If a future component genuinely needs `-Og`, lower the
optimization for `http_parser.c` only rather than globally.

Worth reporting upstream (Zephyr + Espressif toolchain).
