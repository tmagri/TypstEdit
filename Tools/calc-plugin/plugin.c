/* TypstEdit calculator plugin — Typst wasm-minimal-protocol glue.
 *
 * Compiled to wasm32 and loaded by the document bridge as
 * `plugin("TypstEditCalc.wasm")`. Every export takes its arguments as byte
 * buffers (little-endian f64) and returns one little-endian f64, so the Typst
 * wrappers are a single `float.from-bytes(…)` call each.
 *
 * Protocol (Typst docs, "Plugins > Protocol"):
 *   imports (module "typst_env"):
 *     wasm_minimal_protocol_write_args_to_buffer(ptr)
 *     wasm_minimal_protocol_send_result_to_host(ptr, len)
 *   exports: fn(len_1, …, len_n) -> i32   (0 = ok, 1 = error message)
 */

#include "calc_math.h"

/* Generic registry: te_dispatch_call / te_dispatch_names (calc_dispatch.c). */
int te_dispatch_call(const char *name, unsigned int name_len, int arity,
                     const double *args, double *out);
unsigned int te_dispatch_names(char *buffer, unsigned int capacity);
int te_dispatch_abi(void);

__attribute__((import_module("typst_env"),
               import_name("wasm_minimal_protocol_write_args_to_buffer")))
void wasm_minimal_protocol_write_args_to_buffer(unsigned char *ptr);

__attribute__((import_module("typst_env"),
               import_name("wasm_minimal_protocol_send_result_to_host")))
void wasm_minimal_protocol_send_result_to_host(unsigned char *ptr, unsigned int len);

/* ---- linear-memory arena (the plugin owns its input/output buffers) ---- */

static unsigned char te_arena[8192];
static unsigned int te_arena_top;

/* Bump allocator over a fixed arena. Returns NULL when the request cannot fit
 * even in an empty arena, so a caller can never write past the end (the
 * host's write_args_to_buffer writes exactly the requested length). */
static unsigned char *te_alloc(unsigned int len) {
  unsigned int aligned;
  if (len > sizeof(te_arena)) return 0;
  aligned = (te_arena_top + 7u) & ~7u;
  if (aligned > sizeof(te_arena) || len > sizeof(te_arena) - aligned) aligned = 0;
  te_arena_top = aligned + len;
  return &te_arena[aligned];
}

static double te_read_f64(const unsigned char *p) {
  union { double d; unsigned long long u; } c;
  int i;
  c.u = 0;
  for (i = 0; i < 8; i++) c.u |= ((unsigned long long)p[i]) << (8 * i);
  return c.d;
}

static void te_write_f64(unsigned char *p, double v) {
  union { double d; unsigned long long u; } c;
  int i;
  c.d = v;
  for (i = 0; i < 8; i++) p[i] = (unsigned char)(c.u >> (8 * i));
}

/* Copies the call's arguments into plugin memory. NULL if they do not fit;
 * the arguments are then left unread and the call fails with an error. */
static unsigned char *te_read_args(unsigned int total_len) {
  unsigned char *buf = te_alloc(total_len);
  if (buf == 0) return 0;
  wasm_minimal_protocol_write_args_to_buffer(buf);
  return buf;
}

static int te_return_f64(double value) {
  unsigned char *out = te_alloc(8); /* 8 <= arena: never NULL */
  te_write_f64(out, value);
  wasm_minimal_protocol_send_result_to_host(out, 8);
  return 0;
}

static int te_return_error(const char *message, unsigned int len) {
  unsigned char *out = te_alloc(len);
  unsigned int i;
  for (i = 0; i < len; i++) out[i] = (unsigned char)message[i];
  wasm_minimal_protocol_send_result_to_host(out, len);
  return 1;
}

#define TE_INVALID_ARGUMENT(what)                                   \
  do {                                                              \
    return te_return_error("invalid " what, sizeof("invalid " what) - 1u); \
  } while (0)

/* ---- one-argument exports ---- */

__attribute__((export_name("gamma"))) int te_export_gamma(int z_len) {
  unsigned char *args;
  if (z_len != 8) TE_INVALID_ARGUMENT("gamma argument");
  args = te_read_args((unsigned int)z_len);
  if (args == 0) TE_INVALID_ARGUMENT("gamma argument");
  return te_return_f64(te_gamma(te_read_f64(args)));
}

__attribute__((export_name("lgamma"))) int te_export_lgamma(int z_len) {
  unsigned char *args;
  if (z_len != 8) TE_INVALID_ARGUMENT("lgamma argument");
  args = te_read_args((unsigned int)z_len);
  if (args == 0) TE_INVALID_ARGUMENT("lgamma argument");
  return te_return_f64(te_lgamma(te_read_f64(args)));
}

/* ---- two-argument exports (order, x) ---- */

static int te_binary_export(int order_len, int x_len,
                            double (*fn)(double, double)) {
  unsigned char *args;
  double order, x;
  if (order_len != 8 || x_len != 8) TE_INVALID_ARGUMENT("bessel argument");
  args = te_read_args((unsigned int)(order_len + x_len));
  if (args == 0) TE_INVALID_ARGUMENT("bessel argument");
  order = te_read_f64(args);
  x = te_read_f64(args + order_len);
  return te_return_f64(fn(order, x));
}

__attribute__((export_name("bessel_j")))
int te_export_bessel_j(int order_len, int x_len) {
  return te_binary_export(order_len, x_len, te_bessel_j);
}

__attribute__((export_name("bessel_y")))
int te_export_bessel_y(int order_len, int x_len) {
  return te_binary_export(order_len, x_len, te_bessel_y);
}

__attribute__((export_name("bessel_i")))
int te_export_bessel_i(int order_len, int x_len) {
  return te_binary_export(order_len, x_len, te_bessel_i);
}

__attribute__((export_name("bessel_k")))
int te_export_bessel_k(int order_len, int x_len) {
  return te_binary_export(order_len, x_len, te_bessel_k);
}


/* ---- generic dispatch ----------------------------------------------------
 *
 * One entry point per arity. Buffer 0 is the UTF-8 function name; the rest
 * are little-endian f64 arguments. This is what `#calc-call("name", …)` in the
 * bridge uses, so a new function needs no new wasm export — only a row in
 * calc_dispatch.c.
 *
 * Return codes follow the protocol: 0 = ok, 1 = error text in the result
 * buffer.
 */

static int te_call_arity(int name_len, const int *arg_lens, int arity) {
  unsigned int total = (unsigned int)name_len;
  unsigned char *buffer;
  double args[3];
  double value = 0.0;
  int status;
  int i;
  int offset;

  if (name_len <= 0) {
    return te_return_error("missing function name", sizeof("missing function name") - 1u);
  }
  if (name_len > 64) {
    return te_return_error("unknown function", sizeof("unknown function") - 1u);
  }
  for (i = 0; i < arity; i++) {
    /* Every argument is exactly one little-endian f64. */
    if (arg_lens[i] != 8) return te_return_error("arguments must be 8-byte floats", sizeof("arguments must be 8-byte floats") - 1u);
    total += (unsigned int)arg_lens[i];
  }

  buffer = te_read_args(total);
  if (buffer == 0) return te_return_error("arguments too large", sizeof("arguments too large") - 1u);

  offset = name_len;
  for (i = 0; i < arity; i++) {
    args[i] = te_read_f64(buffer + offset);
    offset += arg_lens[i];
  }

  status = te_dispatch_call((const char *)buffer, (unsigned int)name_len, arity, args, &value);
  if (status == 1) {
    return te_return_error("unknown function", sizeof("unknown function") - 1u);
  }
  if (status == 2) {
    return te_return_error("wrong number of arguments", sizeof("wrong number of arguments") - 1u);
  }
  return te_return_f64(value);
}

__attribute__((export_name("call1")))
int te_export_call1(int name_len, int a_len) {
  int lens[1];
  lens[0] = a_len;
  return te_call_arity(name_len, lens, 1);
}
/* `functions` ignores its argument; it is still read so the protocol's
 * write_args contract holds. */

__attribute__((export_name("call2")))
int te_export_call2(int name_len, int a_len, int b_len) {
  int lens[2];
  lens[0] = a_len;
  lens[1] = b_len;
  return te_call_arity(name_len, lens, 2);
}

__attribute__((export_name("call3")))
int te_export_call3(int name_len, int a_len, int b_len, int c_len) {
  int lens[3];
  lens[0] = a_len;
  lens[1] = b_len;
  lens[2] = c_len;
  return te_call_arity(name_len, lens, 3);
}

static char te_name_buffer[4096];

__attribute__((export_name("functions")))
int te_export_functions(int unused_len) {
  unsigned int length;
  if (unused_len > 0 && te_read_args((unsigned int)unused_len) == 0) {
    return te_return_error("arguments too large", sizeof("arguments too large") - 1u);
  }
  length = te_dispatch_names(te_name_buffer, sizeof(te_name_buffer));
  if (length == 0 || length > sizeof(te_arena)) {
    return te_return_error("function list too large", sizeof("function list too large") - 1u);
  }
  {
    unsigned char *out = te_alloc(length);
    unsigned int i;
    for (i = 0; i < length; i++) out[i] = (unsigned char)te_name_buffer[i];
    wasm_minimal_protocol_send_result_to_host(out, length);
  }
  return 0;
}

__attribute__((export_name("abi_version")))
int te_export_abi_version2(int unused_len) {
  if (unused_len > 0 && te_read_args((unsigned int)unused_len) == 0) {
    return te_return_error("arguments too large", sizeof("arguments too large") - 1u);
  }
  return te_return_f64((double)te_dispatch_abi());
}
