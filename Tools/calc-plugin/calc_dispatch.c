/* TypstEdit calculator plugin — function registry.
 *
 * A document reaches every function through one entry point:
 *
 *     #calc-call("besselj", 0, 2.5)
 *
 * The registry below is the single source of truth for what exists. Adding a
 * function is one row: name, arity, implementation. Nothing else in the app
 * needs to change (the Typst bridge dispatches by name, and the scanner reads
 * names from the bridge file).
 *
 * Names are matched case-insensitively, and aliases are cheap: several rows
 * may point at the same implementation.
 */

#include "calc_math.h"

typedef struct te_function {
  const char *name;
  int arity; /* 1..3 arguments */
  double (*unary)(double);
  double (*binary)(double, double);
  double (*ternary)(double, double, double);
} te_function;

/* ---- small adapters for the elementary functions ----
 * Every adapter is total: NaN in gives NaN out, infinities follow IEEE/C99,
 * and nothing casts a double to an integer type (undefined behaviour for
 * NaN/inf/huge values; it saturates silently in wasm). */

static int te_nan(double x) { return x != x; }

static double te_pow_adapter(double a, double b) { return te_pow(a, b); }
static double te_log_base(double x, double b) { return te_log(x) / te_log(b); }
static double te_mod(double a, double b) { return te_fmod(a, b); }
static double te_max2(double a, double b) { return (te_nan(a) || te_nan(b)) ? (a + b) : (a > b ? a : b); }
static double te_min2(double a, double b) { return (te_nan(a) || te_nan(b)) ? (a + b) : (a < b ? a : b); }
static double te_log10(double x) { return te_log(x) / 2.30258509299404568402; }
static double te_log2(double x) { return te_log(x) / 0.69314718055994530942; }
static double te_deg(double x) { return x * 57.29577951308232087680; }
static double te_rad(double x) { return x * 0.01745329251994329576924; }
static double te_frac(double x) { return (x == x && x - x == 0.0) ? x - te_trunc(x) : (x - x); }
static double te_abs_impl(double x) { return x < 0.0 ? -x : (x == 0.0 ? 0.0 : x); }
static double te_sqrt_impl(double x) { return __builtin_sqrt(x); }
static double te_sign_impl(double x) {
  if (te_nan(x)) return x;
  return x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : x); /* keeps ±0 */
}

/* Rounds x to `digits` decimal places, half away from zero. Only exact
 * powers of ten (|digits| <= 22) are used, so the scale adds no error. */
static double te_round_to(double x, double digits) {
  double scale = 1.0, scaled, rounded;
  int i, n;
  if (te_nan(x) || te_nan(digits) || digits != te_trunc(digits)) return 0.0 / 0.0;
  if (digits > 22.0 || digits < -22.0) return 0.0 / 0.0;
  if (x - x != 0.0) return x; /* infinities */
  n = (int)(digits < 0.0 ? -digits : digits);
  for (i = 0; i < n; i++) scale *= 10.0;
  scaled = digits >= 0.0 ? x * scale : x / scale;
  rounded = te_round(scaled);
  return digits >= 0.0 ? rounded / scale : rounded * scale;
}

/* ---- the registry ---- */

static const te_function te_functions[] = {
    /* elementary */
    {"exp", 1, te_exp, 0, 0},
    {"ln", 1, te_log, 0, 0},
    {"log", 1, te_log, 0, 0},
    {"log10", 1, te_log10, 0, 0},
    {"log2", 1, te_log2, 0, 0},
    {"logb", 2, 0, te_log_base, 0},
    {"sqrt", 1, te_sqrt_impl, 0, 0},
    {"cbrt", 1, te_cbrt, 0, 0},
    {"pow", 2, 0, te_pow_adapter, 0},
    {"hypot", 2, 0, te_hypot, 0},
    {"sin", 1, te_sin, 0, 0},
    {"cos", 1, te_cos, 0, 0},
    {"tan", 1, te_tan, 0, 0},
    {"asin", 1, te_asin, 0, 0},
    {"arcsin", 1, te_asin, 0, 0},
    {"acos", 1, te_acos, 0, 0},
    {"arccos", 1, te_acos, 0, 0},
    {"atan", 1, te_atan, 0, 0},
    {"arctan", 1, te_atan, 0, 0},
    {"atan2", 2, 0, te_atan2, 0},
    {"sinh", 1, te_sinh, 0, 0},
    {"cosh", 1, te_cosh, 0, 0},
    {"tanh", 1, te_tanh, 0, 0},
    {"asinh", 1, te_asinh, 0, 0},
    {"acosh", 1, te_acosh, 0, 0},
    {"atanh", 1, te_atanh, 0, 0},
    {"sinc", 1, te_sinc, 0, 0},
    {"deg", 1, te_deg, 0, 0},
    {"rad", 1, te_rad, 0, 0},
    {"abs", 1, te_abs_impl, 0, 0},
    {"floor", 1, te_floor, 0, 0},
    {"ceil", 1, te_ceil, 0, 0},
    {"trunc", 1, te_trunc, 0, 0},
    {"frac", 1, te_frac, 0, 0},
    {"round", 1, te_round, 0, 0},
    {"roundto", 2, 0, te_round_to, 0},
    {"sign", 1, te_sign_impl, 0, 0},
    {"min", 2, 0, te_min2, 0},
    {"max", 2, 0, te_max2, 0},
    {"mod", 2, 0, te_mod, 0},
    {"gcd", 2, 0, te_gcd, 0},
    {"lcm", 2, 0, te_lcm, 0},

    /* gamma family and combinatorics */
    {"gamma", 1, te_gamma, 0, 0},
    {"lgamma", 1, te_lgamma, 0, 0},
    {"digamma", 1, te_digamma, 0, 0},
    {"beta", 2, 0, te_beta, 0},
    {"factorial", 1, te_factorial, 0, 0},
    {"fact", 1, te_factorial, 0, 0},
    {"binom", 2, 0, te_binom, 0},
    {"comb", 2, 0, te_binom, 0},
    {"npr", 2, 0, te_npr, 0},
    {"perm", 2, 0, te_npr, 0},

    /* error and incomplete functions */
    {"erf", 1, te_erf, 0, 0},
    {"erfc", 1, te_erfc, 0, 0},
    {"erfinv", 1, te_erfinv, 0, 0},
    {"gammainc", 2, 0, te_gammainc_p, 0},
    {"gammaincc", 2, 0, te_gammainc_q, 0},
    {"betainc", 3, 0, 0, te_betainc},

    /* integrals and series */
    {"ei", 1, te_ei, 0, 0},
    {"e1", 1, te_e1, 0, 0},
    {"li", 1, te_li, 0, 0},
    {"si", 1, te_si, 0, 0},
    {"ci", 1, te_ci, 0, 0},

    /* special */
    {"zeta", 1, te_zeta, 0, 0},
    {"lambertw", 1, te_lambert_w, 0, 0},
    {"lambertwm1", 1, te_lambert_wm1, 0, 0},
    {"airyai", 1, te_airy_ai, 0, 0},
    {"airybi", 1, te_airy_bi, 0, 0},

    /* Bessel family */
    {"besselj", 2, 0, te_bessel_j, 0},
    {"bessely", 2, 0, te_bessel_y, 0},
    {"besseli", 2, 0, te_bessel_i, 0},
    {"besselk", 2, 0, te_bessel_k, 0},
    {"sphbesselj", 2, 0, te_sph_bessel_j, 0},
    {"sphbessely", 2, 0, te_sph_bessel_y, 0},

    /* orthogonal polynomials (integer order) */
    {"legendre", 2, 0, te_legendre_p, 0},
    {"chebyt", 2, 0, te_chebyshev_t, 0},
    {"chebyu", 2, 0, te_chebyshev_u, 0},
    {"hermite", 2, 0, te_hermite_h, 0},
    {"laguerre", 2, 0, te_laguerre_l, 0},

    /* elliptic */
    {"ellipk", 1, te_ellip_k, 0, 0},
    {"ellipe", 1, te_ellip_e, 0, 0},
    {"jacobisn", 2, 0, te_jacobi_sn, 0},
    {"jacobicn", 2, 0, te_jacobi_cn, 0},
    {"jacobidn", 2, 0, te_jacobi_dn, 0},
};

#define TE_FUNCTION_COUNT ((int)(sizeof(te_functions) / sizeof(te_functions[0])))

/* ---- helpers used by the registry ---- */

/* ASCII case-insensitive comparison (no libc). */
static int te_name_equals(const char *a, unsigned int a_len, const char *b) {
  unsigned int i;
  for (i = 0; i < a_len; i++) {
    char ca = a[i], cb = b[i];
    if (cb == '\0') return 0;
    if (ca >= 'A' && ca <= 'Z') ca = (char)(ca - 'A' + 'a');
    if (cb >= 'A' && cb <= 'Z') cb = (char)(cb - 'A' + 'a');
    if (ca != cb) return 0;
  }
  return b[a_len] == '\0';
}

/* Looks up `name` (not NUL-terminated, `name_len` bytes) and reports whether
 * the arity matches. Returns NULL when unknown or when the arity differs. */
static const te_function *te_lookup(const char *name, unsigned int name_len, int arity) {
  int i;
  for (i = 0; i < TE_FUNCTION_COUNT; i++) {
    const te_function *candidate = &te_functions[i];
    if (candidate->arity != arity) continue;
    if (!te_name_equals(name, name_len, candidate->name)) continue;
    return candidate;
  }
  return 0;
}

/* True when the name exists with any arity — used to distinguish "unknown
 * function" from "wrong number of arguments". */
static int te_known_name(const char *name, unsigned int name_len) {
  int i;
  for (i = 0; i < TE_FUNCTION_COUNT; i++) {
    if (te_name_equals(name, name_len, te_functions[i].name)) return 1;
  }
  return 0;
}

/* Name list for the bridge's `calc-functions()`, newline separated.
 * `buffer` must hold at least TE_NAME_LIST_MAX bytes. */
#define TE_NAME_LIST_MAX 4096

static unsigned int te_name_list(char *buffer, unsigned int capacity) {
  unsigned int used = 0;
  int i;
  for (i = 0; i < TE_FUNCTION_COUNT; i++) {
    const char *name = te_functions[i].name;
    unsigned int len = 0;
    while (name[len] != '\0') len++;
    if (used + len + 3 > capacity) return 0; /* never truncate silently */
    {
      unsigned int j;
      for (j = 0; j < len; j++) buffer[used++] = name[j];
    }
    buffer[used++] = '/';
    buffer[used++] = (char)('0' + te_functions[i].arity);
    buffer[used++] = '\n';
  }
  return used;
}

/* ---- public dispatch API (used by plugin.c) ---- */

/* Returns 0 on success, 1 when the name is unknown, 2 on an arity mismatch. */
int te_dispatch_call(const char *name, unsigned int name_len, int arity,
                     const double *args, double *out) {
  const te_function *function = te_lookup(name, name_len, arity);
  if (function == 0) {
    return te_known_name(name, name_len) ? 2 : 1;
  }
  switch (arity) {
    case 1:
      if (function->unary == 0) return 2;
      *out = function->unary(args[0]);
      return 0;
    case 2:
      if (function->binary == 0) return 2;
      *out = function->binary(args[0], args[1]);
      return 0;
    case 3:
      if (function->ternary == 0) return 2;
      *out = function->ternary(args[0], args[1], args[2]);
      return 0;
    default:
      return 2;
  }
}

/* Writes the newline-separated function list; returns the byte count. */
unsigned int te_dispatch_names(char *buffer, unsigned int capacity) {
  return te_name_list(buffer, capacity);
}

/* ABI marker so a stale .wasm is detectable. */
int te_dispatch_abi(void) { return 2; }
