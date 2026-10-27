/* TypstEdit calculator plugin — numeric core implementation.
 *
 * See calc_math.h for the contract. No libc, no math.h: this file must
 * compile for wasm32-freestanding.
 *
 * Provenance of the algorithms:
 *  - exp/log/sin/cos kernels: fdlibm (Sun Microsystems, freely licensed),
 *    restructured for this file. The polynomial coefficients are fdlibm's.
 *  - gamma/lgamma: Lanczos g=7, n=9 (the classical coefficients).
 *  - Bessel J/Y/I/K: power series with ratio recurrence (no overflowing
 *    factorials) below |x| = 30, Hankel/asymptotic expansions above.
 *    Verified against scipy in Tools/calc-plugin/tests/test_numerics.c.
 */

#include "calc_math.h"

#define TE_PI 3.14159265358979323846
#define TE_E 2.71828182845904523536

/* ---------- bit helpers and tiny primitives (no libc) ---------- */

typedef union { double d; unsigned long long u; } te_bits;

#define TE_NAN (0.0 / 0.0)
#define TE_INF (1.0 / 0.0)

static double te_abs(double x) { return x < 0.0 ? -x : x; }

static int te_isnan(double x) {
  te_bits b;
  b.d = x;
  return ((b.u >> 52) & 0x7FFULL) == 0x7FFULL && (b.u & 0xFFFFFFFFFFFFFULL) != 0;
}

static int te_isinf(double x) {
  te_bits b;
  b.d = x;
  return ((b.u >> 52) & 0x7FFULL) == 0x7FFULL && (b.u & 0xFFFFFFFFFFFFFULL) == 0;
}

static int te_isfinite(double x) { return !te_isnan(x) && !te_isinf(x); }

/* Round to nearest integer, ties away from zero. x86/arm semantics are
 * irrelevant here — only the value matters. */
/* Integer part toward zero, defined for every double. A plain cast is
 * undefined behaviour for NaN, infinities and |x| >= 2^63 (and in wasm it
 * silently saturates to 9.2e18). Values with |x| >= 2^52 are already
 * integers, so they pass through unchanged, as do NaN and infinities. */
double te_trunc(double x) {
  if (!(x > -4503599627370496.0 && x < 4503599627370496.0)) return x;
  if (x == 0.0) return x; /* keeps the sign of zero */
  {
    double t = (double)(long long)x;
    return (t == 0.0 && x < 0.0) ? -0.0 : t;
  }
}

double te_floor(double x) {
  double t = te_trunc(x);
  return (t > x) ? t - 1.0 : t;
}

double te_ceil(double x) {
  double t = te_trunc(x);
  return (t < x) ? t + 1.0 : t;
}

/* Round half away from zero. Exact: x - trunc(x) is exact below 2^52. */
double te_round(double x) {
  double t = te_trunc(x);
  double d = x - t;
  if (!(x > -4503599627370496.0 && x < 4503599627370496.0)) return x;
  if (d >= 0.5) return t + 1.0;
  if (d <= -0.5) return t - 1.0;
  return t;
}

/* Exact floating-point remainder with the sign of a (C fmod semantics).
 * Uses scaled subtraction: every step is exact by Sterbenz' lemma. */
double te_fmod(double a, double b) {
  double r, m, t;
  int negative;
  if (a != a || b != b || b == 0.0) return 0.0 / 0.0;
  if (a == 1.0 / 0.0 || a == -1.0 / 0.0) return 0.0 / 0.0;
  if (b == 1.0 / 0.0 || b == -1.0 / 0.0) return a;
  negative = a < 0.0;
  r = negative ? -a : a;
  m = b < 0.0 ? -b : b;
  if (r < m) return a;
  t = m;
  while (t <= r * 0.5) t *= 2.0; /* largest m·2^k <= r */
  while (t >= m) {
    if (r >= t) r -= t;
    t *= 0.5;
  }
  if (r == 0.0) return negative ? -0.0 : 0.0;
  return negative ? -r : r;
}

static double te_sqrt(double x) { return __builtin_sqrt(x); }

/* Integer exponent test used by pow and by Bessel integer-order logic. */
double te_trunc(double x);
double te_floor(double x);
double te_ceil(double x);
double te_round(double x);

static double te_exp_lgamma_combination(double la, double lb, double lc);

/* Exactly an integer (pow parity, factorial, polynomial degrees, poles). */
static int te_is_integer(double x) {
  return te_isfinite(x) && x == te_trunc(x);
}



/* ---------- exp ---------- */

/* fdlibm __ieee754_exp. */
double te_exp(double x) {
  static const double
      one = 1.0,
      halF[2] = {0.5, -0.5},
      o_threshold = 7.09782712893383973096e+02,
      u_threshold = -7.45133219101941108420e+02,
      ln2HI[2] = {6.93147180369123816490e-01, -6.93147180369123816490e-01},
      ln2LO[2] = {1.90821492927058770002e-10, -1.90821492927058770002e-10},
      invln2 = 1.44269504088896338700e+00,
      P1 = 1.66666666666666019037e-01,
      P2 = -2.77777777770155933842e-03,
      P3 = 6.61375632143793436117e-05,
      P4 = -1.65339022054652515390e-06,
      P5 = 4.13813679705723846039e-08;
  double y, hi = 0.0, lo = 0.0, c, t;
  int k = 0;
  te_bits b;
  b.d = x;

  if (te_isnan(x)) return x;
  if (x > o_threshold) return TE_INF;
  if (x < u_threshold) return 0.0;
  /* fdlibm's three-way range split. The polynomial below is only accurate
   * for |x| <= 0.5 ln2, so the middle band [0.5 ln2, 1.5 ln2] reduces with
   * k = ±1 explicitly; the general band rounds to the nearest multiple. */
  if (te_abs(x) < 0.5 * 6.93147180369123816490e-01) {
    k = 0;
    hi = x;
    lo = 0.0;
  } else if (te_abs(x) < 1.5 * 6.93147180369123816490e-01) {
    if (x > 0.0) {
      hi = x - ln2HI[0];
      lo = ln2LO[0];
      k = 1;
    } else {
      hi = x - ln2HI[1];
      lo = ln2LO[1];
      k = -1;
    }
  } else {
    if (x > 0.0) {
      k = (int)(invln2 * x + halF[0]);
    } else {
      k = (int)(invln2 * x + halF[1]);
    }
    hi = x - (double)k * ln2HI[0];
    lo = (double)k * ln2LO[0];
  }
  x = hi - lo;
  t = x * x;
  c = x - t * (P1 + t * (P2 + t * (P3 + t * (P4 + t * P5))));
  if (k == 0) {
    return one - ((x * c) / (c - 2.0) - x);
  }
  y = one - ((lo - (x * c) / (2.0 - c)) - hi);
  if (k >= -1021) {
    te_bits s;
    s.d = y;
    s.u += ((unsigned long long)k) << 52;
    return s.d;
  }
  /* subnormal range: scale in two steps */
  {
    te_bits s;
    s.d = y;
    s.u += ((unsigned long long)(k + 1000)) << 52;
    return s.d * 9.33263618503218878990e-302; /* 2^-1000 */
  }
}

/* ---------- log ---------- */

/* fdlibm __ieee754_log. */
double te_log(double x) {
  static const double
      ln2_hi = 6.93147180369123816490e-01,
      ln2_lo = 1.90821492927058770002e-10,
      two54 = 1.80143985094819840000e+16,
      Lg1 = 6.666666666666735130e-01,
      Lg2 = 3.999999999940941908e-01,
      Lg3 = 2.857142874366239149e-01,
      Lg4 = 2.222219843214978396e-01,
      Lg5 = 1.818357216161805012e-01,
      Lg6 = 1.531383769920937332e-01,
      Lg7 = 1.479819860511658591e-01;
  double hfsq, f, s, z, R, w, t1, t2, dk;
  int k, hx, i, j;
  te_bits b;
  b.d = x;
  hx = (int)(b.u >> 32);

  k = 0;
  if (hx < 0x00100000) { /* x < 2^-1022 */
    if (((hx & 0x7FFFFFFF) | (int)(b.u & 0xFFFFFFFFULL)) == 0) return -TE_INF;
    if (hx < 0) return TE_NAN;
    k -= 54;
    x *= two54;
    b.d = x;
    hx = (int)(b.u >> 32);
  }
  if (hx >= 0x7FF00000) return x + x;

  k += (hx >> 20) - 1023;
  hx &= 0x000FFFFF;
  i = (hx + 0x95F64) & 0x100000;
  b.d = x;
  b.u = (b.u & 0xFFFFFFFFULL) | (((unsigned long long)(hx | (i ^ 0x3FF00000))) << 32);
  x = b.d;
  k += (i >> 20);
  f = x - 1.0;
  if ((0x000FFFFF & (2 + hx)) < 3) { /* |f| < 2^-20 */
    if (f == 0.0) {
      if (k == 0) return 0.0;
      dk = (double)k;
      return dk * ln2_hi + dk * ln2_lo;
    }
    R = f * f * (0.5 - 0.33333333333333333 * f);
    if (k == 0) return f - R;
    dk = (double)k;
    return dk * ln2_hi - ((R - dk * ln2_lo) - f);
  }
  s = f / (2.0 + f);
  dk = (double)k;
  z = s * s;
  i = hx - 0x6147A;
  w = z * z;
  j = 0x6B851 - hx;
  t1 = w * (Lg2 + w * (Lg4 + w * Lg6));
  t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
  i |= j;
  R = t2 + t1;
  if (i > 0) {
    hfsq = 0.5 * f * f;
    if (k == 0) return f - (hfsq - s * (hfsq + R));
    return dk * ln2_hi - ((hfsq - (s * (hfsq + R) + dk * ln2_lo)) - f);
  }
  if (k == 0) return f - s * (f - R);
  return dk * ln2_hi - ((s * (f - R) - dk * ln2_lo) - f);
}

/* ---------- pow ---------- */

static int te_signbit(double x) {
  te_bits b;
  b.d = x;
  return (int)(b.u >> 63);
}

static int te_is_odd_integer(double x) {
  double half;
  if (!te_isfinite(x) || te_abs(x) >= 9007199254740992.0) return 0;
  if (x != te_trunc(x)) return 0;
  half = x * 0.5;
  return half != te_trunc(half);
}

double te_pow(double base, double exponent) {
  if (exponent == 0.0) return 1.0;
  if (base == 1.0) return 1.0;
  if (te_isnan(base) || te_isnan(exponent)) return TE_NAN;
  if (te_isinf(exponent)) {
    double ab = te_abs(base);
    if (ab == 1.0) return 1.0;
    return ((ab < 1.0) == (exponent > 0.0)) ? 0.0 : TE_INF;
  }
  if (base == 0.0) {
    int odd = te_is_odd_integer(exponent);
    if (exponent > 0.0) return (odd && te_signbit(base)) ? -0.0 : 0.0;
    return (odd && te_signbit(base)) ? -TE_INF : TE_INF;
  }

  if (base < 0.0) {
    if (!te_is_integer(exponent)) return TE_NAN;
    double magnitude = te_exp(exponent * te_log(-base));
    /* sign is negative only for odd integer exponents */
    double half = exponent * 0.5;
    int isOdd = te_abs(half - te_round(half)) > 0.25;
    return isOdd ? -magnitude : magnitude;
  }

  /* Exact repeated squaring for small integer exponents: the Bessel series
   * raises the argument to integer orders, where rounding matters. Rounding
   * (not truncating) matters here: a value like 6.9999999999999867 is an
   * integer exponent that a plain cast would turn into 6. */
  if (te_is_integer(exponent) && te_abs(exponent) <= 64.0) {
    int n = (int)te_round(exponent);
    int negative = n < 0;
    double result = 1.0, square = base;
    if (negative) n = -n;
    while (n > 0) {
      if (n & 1) result *= square;
      square *= square;
      n >>= 1;
    }
    return negative ? 1.0 / result : result;
  }
  return te_exp(exponent * te_log(base));
}

/* ---------- sin / cos ---------- */

/* Cody–Waite split of pi/2: the three parts have non-overlapping mantissas,
 * so `x - n*pio2_1 - n*pio2_2 - n*pio2_3` keeps ~17 significant digits of the
 * reduced argument for |x| up to about 1e5. */
static const double te_pio2_1 = 1.57079632673412561417e+00;
static const double te_pio2_1t = 6.07710050650619224932e-11;
static const double te_pio2_2t = 2.02226624879595063154e-21;
static const double te_two_over_pi = 6.36619772367581382433e-01;

/* Reduces x to r in [-pi/4, pi/4]; returns the quadrant n. */
/* Beyond this the Cody–Waite reduction no longer gives the reduced argument
 * to ~1e-10, so sin/cos decline (NaN) instead of returning a wrong value.
 * Measured in tests/test_registry.c. */
#define TE_TRIG_MAX 1.0e10

/* Reduces x to r in [-pi/4, pi/4]; returns the quadrant n mod 4 (0..3). */
static int te_rem_pio2(double x, double *r) {
  double n = te_round(x * te_two_over_pi);
  double reduced = ((x - n * te_pio2_1) - n * te_pio2_1t) - n * te_pio2_2t;
  double quadrant = n - 4.0 * te_floor(n * 0.25); /* exact: |n| < 2^35 */
  *r = reduced;
  return (int)quadrant;
}

/* fdlibm kernels; y is the low-order tail of the reduced argument. */
static double te_kernel_sin(double x, double y) {
  static const double
      S1 = -1.66666666666666324348e-01,
      S2 = 8.33333333332248946124e-03,
      S3 = -1.98412698298579493134e-04,
      S4 = 2.75573137070700676789e-06,
      S5 = -2.50507602534068634195e-08,
      S6 = 1.58969099521155010221e-10;
  double z = x * x;
  double v = z * x;
  double r = S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)));
  if (y == 0.0) return x + v * (S1 + z * r);
  return x - ((z * (0.5 * y - v * r) - y) - v * S1);
}

static double te_kernel_cos(double x, double y) {
  static const double
      C1 = 4.16666666666666019037e-02,
      C2 = -1.38888888888741095749e-03,
      C3 = 2.48015872894767294178e-05,
      C4 = -2.75573143513906633035e-07,
      C5 = 2.08757232129817482790e-09,
      C6 = -1.13596475577881948265e-11;
  double z = x * x;
  double r = z * (C1 + z * (C2 + z * (C3 + z * (C4 + z * (C5 + z * C6)))));
  if (te_abs(x) < 0.3) return 1.0 - (0.5 * z - (z * r - y));
  {
    te_bits b;
    b.d = 1.0 - 0.28125;
    {
      /* hz = 0.5*z - qx with qx = 0.28125 for very small z */
      double qx = (te_abs(x) < 0.78125) ? 0.28125 : 0.0;
      double hz = 0.5 * z - qx;
      double a = 1.0 - qx;
      return a - (hz - (z * r - y));
    }
  }
}

double te_sin(double x) {
  double r;
  int n;
  if (!te_isfinite(x) || te_abs(x) > TE_TRIG_MAX) return TE_NAN;
  if (te_abs(x) < 0.7853981633974483) return te_kernel_sin(x, 0.0);
  n = te_rem_pio2(x, &r);
  switch (n) {
    case 0: return te_kernel_sin(r, 0.0);
    case 1: return te_kernel_cos(r, 0.0);
    case 2: return -te_kernel_sin(r, 0.0);
    default: return -te_kernel_cos(r, 0.0);
  }
}

double te_cos(double x) {
  double r;
  int n;
  if (!te_isfinite(x) || te_abs(x) > TE_TRIG_MAX) return TE_NAN;
  if (te_abs(x) < 0.7853981633974483) return te_kernel_cos(x, 0.0);
  n = te_rem_pio2(x, &r);
  switch (n) {
    case 0: return te_kernel_cos(r, 0.0);
    case 1: return -te_kernel_sin(r, 0.0);
    case 2: return -te_kernel_cos(r, 0.0);
    default: return te_kernel_sin(r, 0.0);
  }
}

/* sin(pi x) and cos(pi x) with exact argument reduction: x - 2 round(x/2) is
 * exact, so reflection formulas stay accurate for large |x|. */
static double te_sinpi(double x) {
  double r;
  if (!te_isfinite(x)) return TE_NAN;
  if (te_abs(x) >= 4503599627370496.0) return 0.0; /* integers */
  r = x - 2.0 * te_round(x * 0.5); /* r in [-1, 1] */
  if (r == 1.0 || r == -1.0 || r == 0.0) return 0.0;
  return te_sin(TE_PI * r);
}

static double te_cospi(double x) {
  double r;
  if (!te_isfinite(x)) return TE_NAN;
  if (te_abs(x) >= 4503599627370496.0) return 1.0;
  r = x - 2.0 * te_round(x * 0.5);
  if (r == 0.5 || r == -0.5) return 0.0;
  return te_cos(TE_PI * r);
}

/* log(1 + x) without cancellation for small x (Goldberg's trick). */
static double te_log1p(double x) {
  double u = 1.0 + x;
  if (u == 1.0) return x;
  if (!te_isfinite(u)) return te_log(u);
  return te_log(u) * x / (u - 1.0);
}

/* ---------- gamma (Lanczos g=7, n=9; Stirling for large z) ---------- */

static double te_lgamma_stirling(double z);

static const double te_lanczos[9] = {
    0.99999999999980993, 676.5203681218851, -1259.1392167224028,
    771.32342877765313, -176.61502916214059, 12.507343278686905,
    -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7};

double te_gamma(double z) {
  int i;
  double zz, sum, t;
  if (te_isnan(z)) return z;
  if (z > 0.0 && z <= 171.0 && te_is_integer(z)) { /* exact: (z-1)! */
    double result = 1.0, i;
    for (i = 2.0; i < z; i += 1.0) result *= i;
    return result;
  }
  if (z >= 10.0) return te_exp(te_lgamma(z));
  if (z < 0.5) {
    /* reflection formula; the poles of sin(pi*z) surface as NaN/inf */
    double s = te_sinpi(z);
    if (s == 0.0) return TE_NAN; /* poles at non-positive integers */
    return 3.14159265358979323846 / (s * te_gamma(1.0 - z));
  }
  zz = z - 1.0;
  sum = te_lanczos[0];
  for (i = 1; i < 9; i++) sum += te_lanczos[i] / (zz + i);
  t = zz + 7.5;
  if (t <= 0.0) return TE_NAN;
  return te_sqrt(2.0 * 3.14159265358979323846) * te_pow(t, zz + 0.5) * te_exp(-t) * sum;
}

double te_lgamma(double z) {
  if (te_isnan(z)) return z;
  if (te_isinf(z)) return TE_INF;
  if (z == 1.0 || z == 2.0) return 0.0;
  if (z <= 0.0) {
    double s;
    if (te_is_integer(z)) return TE_INF; /* poles */
    s = te_sinpi(z);
    if (s == 0.0) return TE_INF;
    /* ln|Gamma(z)| = ln(pi / |sin(pi z)|) - ln Gamma(1 - z) */
    return te_log(TE_PI / te_abs(s)) - te_lgamma(1.0 - z);
  }
  if (z < 10.0) return te_log(te_abs(te_gamma(z))); /* Lanczos: ~1e-15 */
  return te_lgamma_stirling(z);
}

/* ---------- Bessel functions ---------- */

#define TE_EULER 0.57721566490153286061
#define TE_SERIES_MAX_X 12.0
/* Series/asymptotic crossovers. Below them the power series converges without
 * catastrophic cancellation; above them the Hankel expansions are accurate to
 * ~1e-7 (J/Y) and ~1e-8 (K) for the orders documents use.
 *
 * J and Y are O(1/sqrt x), so their series survives to x = 18. K decays like
 * e^-x while its integer-order series sums O(1) terms that cancel, so it must
 * switch to the exponential asymptotic much earlier. */
#define TE_ASYM_MIN_X 18.0
#define TE_ASYM_MIN_X_K 11.0

/* H_n = 1 + 1/2 + … + 1/n (H_0 = 0). */
static double te_harmonic(int n) {
  double sum = 0.0;
  int i;
  for (i = 1; i <= n; i++) sum += 1.0 / (double)i;
  return sum;
}

/* psi(k+1) = H_k - gamma. */
static double te_psi1(int k) { return te_harmonic(k) - TE_EULER; }

/* J_p(x) power series with ratio recurrence: no factorial overflow.
 * Multiplication order matters for precision; the leading term is computed
 * first and then each term follows from the previous one. */
static int te_is_odd(double n) {
  double half = n * 0.5;
  return half != te_trunc(half);
}

/* J_p(x) for x >= 0 by power series (ratio recurrence, no factorial
 * overflow). The leading term is formed in log space so huge orders underflow
 * cleanly to 0 instead of producing inf/inf. NaN if it does not converge. */
static double te_bessel_j_series_positive(double x, double p) {
  double half = x * 0.5, q = half * half, lead, total, term;
  int k;
  if (half == 0.0) {
    if (p == 0.0) return 1.0;
    if (p > 0.0 || te_is_integer(p)) return 0.0;
    return TE_NAN;
  }
  lead = (p + 1.0 > 0.0) ? te_exp(p * te_log(half) - te_lgamma(p + 1.0))
                         : te_pow(half, p) / te_gamma(p + 1.0);
  if (lead == 0.0) return 0.0;
  if (!te_isfinite(lead)) return TE_NAN;
  total = lead;
  term = lead;
  for (k = 0; k < 4000; k++) {
    term = term * (-q) / (((double)k + 1.0) * (p + (double)k + 1.0));
    total += term;
    if (te_abs(term) <= 1e-17 * te_abs(total)) return total;
  }
  return TE_NAN;
}

/* I_p(x) power series (positive terms). */
/* I_p(x) for x >= 0 by power series. All terms are positive, so there is no
 * cancellation; it converges for every finite x (I overflows to inf before
 * the iteration cap matters). NaN if it does not converge. */
static double te_bessel_i_series(double x, double p) {
  double half = x * 0.5, q = half * half, lead, total, term;
  int k;
  if (half == 0.0) {
    if (p == 0.0) return 1.0;
    if (p > 0.0 || te_is_integer(p)) return 0.0;
    return TE_NAN;
  }
  lead = (p + 1.0 > 0.0) ? te_exp(p * te_log(half) - te_lgamma(p + 1.0))
                         : te_pow(half, p) / te_gamma(p + 1.0);
  if (lead == 0.0) return 0.0;
  if (te_isnan(lead)) return TE_NAN;
  total = lead;
  term = lead;
  for (k = 0; k < 4000; k++) {
    term = term * q / (((double)k + 1.0) * (p + (double)k + 1.0));
    total += term;
    if (!te_isfinite(total)) return total;
    if (te_abs(term) <= 1e-17 * te_abs(total)) return total;
  }
  return TE_NAN;
}

/* P and Q auxiliary series shared by the J and Y asymptotics. */
static void te_hankel_pq(double x, double p, double *P, double *Q) {
  double mu = 4.0 * p * p;
  double m8 = 8.0 * x;
  double p1 = mu - 1.0;
  double p2 = p1 * (mu - 9.0);
  double p3 = p2 * (mu - 25.0);
  double p4 = p3 * (mu - 49.0);
  double p5 = p4 * (mu - 81.0);
  double p6 = p5 * (mu - 121.0);
  double p7 = p6 * (mu - 169.0);
  double p8 = p7 * (mu - 225.0);
  double m8_2 = m8 * m8;
  double m8_3 = m8_2 * m8;
  double m8_4 = m8_2 * m8_2;
  double m8_5 = m8_4 * m8;
  double m8_6 = m8_3 * m8_3;
  double m8_7 = m8_6 * m8;
  double m8_8 = m8_4 * m8_4;
  *P = 1.0 - p2 / (2.0 * m8_2) + p4 / (24.0 * m8_4) - p6 / (720.0 * m8_6) +
       p8 / (40320.0 * m8_8);
  *Q = p1 / m8 - p3 / (6.0 * m8_3) + p5 / (120.0 * m8_5) - p7 / (5040.0 * m8_7);
}

static double te_bessel_j_asymptotic(double x, double p) {
  double P, Q, chi, pref;
  te_hankel_pq(x, p, &P, &Q);
  chi = x - (p * TE_PI * 0.5 + TE_PI * 0.25);
  pref = te_sqrt(2.0 / (TE_PI * x));
  return pref * (P * te_cos(chi) - Q * te_sin(chi));
}

static double te_bessel_y_asymptotic(double x, double p) {
  double P, Q, chi, pref;
  te_hankel_pq(x, p, &P, &Q);
  chi = x - (p * TE_PI * 0.5 + TE_PI * 0.25);
  pref = te_sqrt(2.0 / (TE_PI * x));
  return pref * (P * te_sin(chi) + Q * te_cos(chi));
}

/* Y_n(x) for a non-negative integer order, small/medium x:
 *
 *   Y_n = (2/pi) ln(x/2) J_n
 *       - (1/pi) sum_{k=0}^{n-1} (n-k-1)!/k! (x/2)^{2k-n}
 *       - (1/pi) sum_{k>=0} (-1)^k (psi(k+1)+psi(n+k+1))/(k!(n+k)!) (x/2)^{2k+n}
 *
 * This is the exact integer-order form (A&S 9.1.11); it avoids the
 * catastrophic cancellation of the reflection formula at integer order. */
static double te_bessel_y_integer(int n, double x) {
  double half = x * 0.5;
  double jn = te_bessel_j_series_positive(x, (double)n);
  double sum = 0.0;
  double term;
  int k;

  /* finite sum */
  for (k = 0; k < n; k++) {
    /* (n-k-1)!/k! * half^(2k-n) */
    double coeff = 1.0;
    int i;
    for (i = 1; i <= n - k - 1; i++) coeff *= (double)i; /* (n-k-1)! */
    for (i = 1; i <= k; i++) coeff /= (double)i;         /* /k! */
    coeff *= te_pow(half, (double)(2 * k - n));
    sum += coeff;
  }

  /* infinite sum, ratio recurrence */
  {
    double power = te_pow(half, (double)n);              /* half^n */
    double factorial = 1.0;
    int i;
    for (i = 1; i <= n; i++) factorial *= (double)i;     /* n! */
    term = power * (te_psi1(0) + te_psi1(n)) / factorial;
    {
      double infinite = term;
      for (k = 0; k < 400; k++) {
        /* t_{k+1}/t_k = -(half^2) * (psi(k+2)+psi(n+k+2)) /
         *               ((psi(k+1)+psi(n+k+1)) * (k+1) * (n+k+1)) */
        double psiNow = te_psi1(k) + te_psi1(n + k);
        double psiNext = te_psi1(k + 1) + te_psi1(n + k + 1);
        double ratio;
        if (psiNow == 0.0) break;
        ratio = -(half * half) * (psiNext / psiNow) /
                (((double)k + 1.0) * ((double)n + (double)k + 1.0));
        term *= ratio;
        infinite += term;
        if (te_abs(term) < 1e-19 * te_abs(infinite)) break;
      }
      sum += infinite;
    }
  }

  return (2.0 / TE_PI) * te_log(half) * jn - sum / TE_PI;
}

/* K_n(x) for a non-negative integer order, small/medium x:
 *
 *   K_n = (1/2)(x/2)^{-n} sum_{k=0}^{n-1} (n-k-1)!/k! (-x^2/4)^k
 *       + (-1)^{n+1} ln(x/2) I_n
 *       + (-1)^n (1/2)(x/2)^n sum_{k>=0}
 *             (psi(k+1)+psi(n+k+1))/(k!(n+k)!) (x^2/4)^k
 */
static double te_bessel_k_integer(int n, double x) {
  double half = x * 0.5;
  double in = te_bessel_i_series(x, (double)n);
  double sum = 0.0;
  double term;
  int k;
  int sign = (n % 2 == 0) ? 1 : -1;

  /* finite sum */
  for (k = 0; k < n; k++) {
    double coeff = 1.0;
    int i;
    for (i = 1; i <= n - k - 1; i++) coeff *= (double)i;
    for (i = 1; i <= k; i++) coeff /= (double)i;
    /* (-x^2/4)^k = (-1)^k half^(2k) */
    coeff *= te_pow(-half * half, (double)k);
    sum += coeff;
  }
  sum *= 0.5 * te_pow(half, (double)(-n));

  /* infinite sum */
  {
    double factorial = 1.0;
    int i;
    for (i = 1; i <= n; i++) factorial *= (double)i;
    term = (te_psi1(0) + te_psi1(n)) / factorial;
    {
      double infinite = term;
      for (k = 0; k < 400; k++) {
        double psiNow = te_psi1(k) + te_psi1(n + k);
        double psiNext = te_psi1(k + 1) + te_psi1(n + k + 1);
        double ratio;
        if (psiNow == 0.0) break;
        ratio = (half * half) * (psiNext / psiNow) /
                (((double)k + 1.0) * ((double)n + (double)k + 1.0));
        term *= ratio;
        infinite += term;
        if (te_abs(term) < 1e-19 * te_abs(infinite)) break;
      }
      sum += (double)sign * 0.5 * te_pow(half, (double)n) * infinite;
    }
  }

  sum += (double)(-sign) * te_log(half) * in;
  return sum;
}

/* Upper bound on recurrence length (also bounds work per call). */
#define TE_MAX_RECURRENCE 100000.0

/* J for 0 <= nu < 2 at any x >= 0 (both expansions are valid for such small
 * orders on their side of the crossover). */
static double te_j_small_order(double x, double nu) {
  if (x <= TE_ASYM_MIN_X) return te_bessel_j_series_positive(x, nu);
  return te_bessel_j_asymptotic(x, nu);
}

/* Integer-order J_n(x) for n >= x by Miller's backward recurrence, normalised
 * with 1 = J_0 + 2 Σ J_2k (Numerical Recipes, bessj). Stable in this regime. */
static double te_j_miller(int n, double x) {
  const double big = 1e10, small = 1e-10;
  double tox = 2.0 / x, bjp = 0.0, bj = 1.0, bjm, sum = 0.0, answer = 0.0;
  int m = 2 * ((n + (int)te_sqrt(400.0 * n)) / 2);
  int j, jsum = 0;
  for (j = m; j > 0; j--) {
    bjm = (double)j * tox * bj - bjp;
    bjp = bj;
    bj = bjm;
    if (te_abs(bj) > big) {
      bj *= small;
      bjp *= small;
      answer *= small;
      sum *= small;
    }
    if (jsum) sum += bj;
    jsum = !jsum;
    if (j == n) answer = bjp;
  }
  sum = 2.0 * sum - bj;
  return answer / sum;
}

double te_bessel_j(double order, double x) {
  double p, value;
  if (te_isnan(order) || te_isnan(x) || te_isinf(order)) return TE_NAN;
  p = order;
  if (x < 0.0) {
    if (!te_is_integer(p)) return TE_NAN; /* complex */
    value = te_bessel_j(p, -x);
    return te_is_odd(p) ? -value : value;
  }
  if (te_isinf(x)) return 0.0;
  if (p < 0.0 && te_is_integer(p)) { /* J_{-n} = (-1)^n J_n */
    value = te_bessel_j(-p, x);
    return te_is_odd(p) ? -value : value;
  }
  /* Power series: accurate below the crossover, and for any x once the
   * order dominates (p >= x^2/4: terms decrease from the start). */
  if (x <= TE_ASYM_MIN_X || te_abs(p) >= 0.25 * x * x) return te_bessel_j_series_positive(x, p);
  /* Hankel expansion: valid when x is large compared with p^2. */
  if (p * p <= x) return te_bessel_j_asymptotic(x, p);
  /* Forward recurrence from J_nu, J_{nu+1}: stable while the order < x. */
  if (p > 0.0 && p < x) {
    double nu = p - te_floor(p);
    double steps = te_round(p - nu);
    double jm, jc, k;
    if (steps > TE_MAX_RECURRENCE) return TE_NAN;
    jm = te_j_small_order(x, nu);
    if (steps == 0.0) return jm;
    jc = te_j_small_order(x, nu + 1.0);
    if (!te_isfinite(jm) || !te_isfinite(jc)) return TE_NAN;
    for (k = 1.0; k < steps; k += 1.0) {
      double jn = 2.0 * (nu + k) / x * jc - jm;
      jm = jc;
      jc = jn;
    }
    return jc;
  }
  /* Integer orders x <= n < x^2/4: Miller backward recurrence. */
  if (te_is_integer(p) && p > 0.0 && p <= TE_MAX_RECURRENCE) return te_j_miller((int)p, x);
  /* Non-integer order with x <= p < x^2/4: no method here is accurate. */
  return TE_NAN;
}

/* Y for 0 <= nu < 2 at x > 0. */
static double te_y_small_order(double x, double nu) {
  if (te_is_integer(nu)) {
    if (x > TE_ASYM_MIN_X) return te_bessel_y_asymptotic(x, nu);
    return te_bessel_y_integer((int)nu, x);
  }
  if (x > TE_ASYM_MIN_X) return te_bessel_y_asymptotic(x, nu);
  {
    double s = te_sinpi(nu);
    return (te_bessel_j_series_positive(x, nu) * te_cospi(nu) -
            te_bessel_j_series_positive(x, -nu)) / s;
  }
}

double te_bessel_y(double order, double x) {
  double p, nu, steps, ym, yc, k;
  if (te_isnan(order) || te_isnan(x) || te_isinf(order)) return TE_NAN;
  if (x < 0.0) return TE_NAN; /* complex */
  p = order;
  /* The reflection formula used below the crossover divides by sin(pi·v);
   * within 1e-7 of an integer (but not on it) its error would exceed ~1e-10,
   * so the function declines there instead of snapping (snapping errs by up
   * to |dv|·|dY/dv|, which is unbounded as x -> 0). */
  if (!te_is_integer(p) && te_abs(p - te_round(p)) < 1e-7 && x <= TE_ASYM_MIN_X) return TE_NAN;
  if (x == 0.0) return p >= 0.0 ? -TE_INF : TE_NAN;
  if (te_isinf(x)) return 0.0;
  if (p < 0.0) {
    if (te_is_integer(p)) { /* Y_{-n} = (-1)^n Y_n */
      double value = te_bessel_y(-p, x);
      return te_is_odd(p) ? -value : value;
    }
    /* Y_{-v} = cos(v pi) Y_v + sin(v pi) J_v */
    {
      double v = -p, c = te_cospi(v), sn = te_sinpi(v), sum = 0.0;
      /* an exactly-zero coefficient drops its term (avoids 0·inf) */
      if (c != 0.0) sum += c * te_bessel_y(v, x);
      if (sn != 0.0) sum += sn * te_bessel_j(v, x);
      return sum;
    }
  }
  /* Forward recurrence is stable for Y (the dominant solution) at every x. */
  nu = p - te_floor(p);
  steps = te_round(p - nu);
  if (steps > TE_MAX_RECURRENCE) return TE_NAN;
  ym = te_y_small_order(x, nu);
  if (steps == 0.0) return ym;
  yc = te_y_small_order(x, nu + 1.0);
  for (k = 1.0; k < steps; k += 1.0) {
    double yn;
    if (!te_isfinite(yc)) return yc;
    yn = 2.0 * (nu + k) / x * yc - ym;
    ym = yc;
    yc = yn;
  }
  return yc;
}

double te_bessel_i(double order, double x) {
  double p, value;
  if (te_isnan(order) || te_isnan(x) || te_isinf(order)) return TE_NAN;
  p = order;
  if (x < 0.0) {
    if (!te_is_integer(p)) return TE_NAN; /* complex */
    value = te_bessel_i(p, -x);
    return te_is_odd(p) ? -value : value; /* I_n(-x) = (-1)^n I_n(x) */
  }
  if (te_isinf(x)) return TE_INF;
  if (p < 0.0 && te_is_integer(p)) return te_bessel_i(-p, x); /* I_{-n} = I_n */
  return te_bessel_i_series(x, p);
}

/* K for 0 <= nu < 2 at x > 0. */
/* K_mu(x) and K_{mu+1}(x) for |mu| <= 1/2, x >= 2: Steed's continued fraction
 * CF2 (Numerical Recipes, bessik). Converges to full precision, no
 * cancellation. Returns 0 if it fails to converge. */
static int te_k_steed(double x, double mu, double *kmu, double *kmu1) {
  double b = 2.0 * (1.0 + x), d = 1.0 / b, h = d, delh = d;
  double q1 = 0.0, q2 = 1.0, a1 = 0.25 - mu * mu, q = a1, c = a1, a = -a1;
  double sum = 1.0 + q * delh;
  int i;
  for (i = 2; i <= 20000; i++) {
    double qnew, dels;
    a -= 2.0 * (double)(i - 1);
    c = -a * c / (double)i;
    qnew = (q1 - b * q2) / a;
    q1 = q2;
    q2 = qnew;
    q += c * qnew;
    b += 2.0;
    d = 1.0 / (b + a * d);
    delh = (b * d - 1.0) * delh;
    h += delh;
    dels = q * delh;
    sum += dels;
    if (te_abs(dels / sum) < 1e-17) {
      h = a1 * h;
      *kmu = te_sqrt(TE_PI / (2.0 * x)) * te_exp(-x) / sum;
      *kmu1 = *kmu * (mu + x + 0.5 - h) / x;
      return 1;
    }
  }
  return 0;
}

/* K_v for small x (< 2): integer orders by the exact integer-order series
 * (cancellation is at most e^4·eps there), others by the reflection formula. */
static double te_k_small_x(double x, double v) {
  if (te_is_integer(v)) return te_bessel_k_integer((int)v, x);
  return TE_PI * 0.5 * (te_bessel_i_series(x, -v) - te_bessel_i_series(x, v)) / te_sinpi(v);
}

double te_bessel_k(double order, double x) {
  double p, nl, mu, km, kc, k;
  if (te_isnan(order) || te_isnan(x) || te_isinf(order)) return TE_NAN;
  if (x < 0.0) return TE_NAN; /* complex */
  if (x == 0.0) return TE_INF;
  if (te_isinf(x)) return 0.0;
  p = te_abs(order); /* K_{-v} = K_v */
  nl = te_round(p);
  if (nl > TE_MAX_RECURRENCE) return TE_NAN;
  mu = p - nl; /* |mu| <= 1/2 */
  if (x < 2.0 && mu != 0.0 && te_abs(mu) < 1e-7) return TE_NAN; /* reflection ill-conditioned */
  if (x >= 2.0) {
    if (!te_k_steed(x, mu, &km, &kc)) return TE_NAN;
  } else {
    km = te_k_small_x(x, mu);
    kc = te_k_small_x(x, mu + 1.0);
  }
  /* Forward recurrence is stable for K (the dominant solution). */
  for (k = 1.0; k <= nl; k += 1.0) {
    double kn;
    if (!te_isfinite(kc)) return kc;
    kn = (mu + k) * (2.0 / x) * kc + km;
    km = kc;
    kc = kn;
  }
  return km;
}


/* ==========================================================================
 * Generic function library
 *
 * Everything below is reachable from a document as
 *   #calc-call("name", …args)
 * or through the convenience aliases in the bridge. The name registry lives
 * in calc_dispatch.c; adding a function there is the only step needed to make
 * it callable.
 * ========================================================================== */

/* ---------- inverse trig (needed by the elliptic inverse-AGM) ---------- */

double te_atan(double x) {
  /* Half-angle reduction: atan(x) = 2 atan(x / (1 + sqrt(1 + x²))). Four
   * rounds bring |x| under 0.06, where the Taylor series is exact to
   * double precision in a few terms. */
  int negate = x < 0.0;
  int reciprocal = 0;
  double result;
  double term, sum, x2;
  int i, n;
  if (negate) x = -x;
  if (x > 1.0) { x = 1.0 / x; reciprocal = 1; }
  for (i = 0; i < 4; i++) x = x / (1.0 + te_sqrt(1.0 + x * x));
  result = 2.0 * 2.0 * 2.0 * 2.0;
  x2 = x * x;
  term = x;
  sum = x;
  for (n = 1; n < 20; n++) {
    term *= -x2;
    sum += term / (2.0 * n + 1.0);
  }
  result *= sum;
  if (reciprocal) result = TE_PI / 2.0 - result;
  return negate ? -result : result;
}

double te_atan2(double y, double x) {
  /* C99 Annex F special cases, including signed zeros and infinities. */
  int ys = te_signbit(y), xs = te_signbit(x);
  if (te_isnan(x) || te_isnan(y)) return TE_NAN;
  if (y == 0.0) {
    if (xs) return ys ? -TE_PI : TE_PI;
    return y; /* ±0 */
  }
  if (x == 0.0) return ys ? -TE_PI / 2.0 : TE_PI / 2.0;
  if (te_isinf(x)) {
    if (te_isinf(y)) {
      double v = xs ? 3.0 * TE_PI / 4.0 : TE_PI / 4.0;
      return ys ? -v : v;
    }
    if (xs) return ys ? -TE_PI : TE_PI;
    return ys ? -0.0 : 0.0;
  }
  if (te_isinf(y)) return ys ? -TE_PI / 2.0 : TE_PI / 2.0;
  {
    double base = te_atan(y / x);
    if (!xs) return base;
    return base + (ys ? -TE_PI : TE_PI);
  }
}

double te_asin(double x) {
  if (te_isnan(x) || x > 1.0 || x < -1.0) return TE_NAN;
  if (x == 1.0) return TE_PI / 2.0;
  if (x == -1.0) return -TE_PI / 2.0;
  /* (1 - x)(1 + x) avoids the cancellation in 1 - x*x near ±1. */
  return te_atan(x / te_sqrt((1.0 - x) * (1.0 + x)));
}

double te_acos(double x) {
  if (te_isnan(x) || x > 1.0 || x < -1.0) return TE_NAN;
  /* 2 atan(sqrt((1-x)/(1+x))) has no cancellation anywhere on [-1, 1]. */
  return 2.0 * te_atan(te_sqrt((1.0 - x) / (1.0 + x)));
}

double te_tan(double x) {
  double c = te_cos(x);
  if (c == 0.0) return TE_NAN;
  return te_sin(x) / c;
}

double te_sinh(double x) {
  double ax = te_abs(x), v;
  if (te_isnan(x)) return x;
  if (ax < 0.5) { /* Taylor series: (e - 1/e)/2 would cancel */
    double x2 = x * x, term = x, sum = x;
    int n;
    for (n = 1; n < 20; n++) {
      term *= x2 / ((2.0 * n) * (2.0 * n + 1.0));
      sum += term;
    }
    return sum;
  }
  if (ax > 700.0) { /* exp(ax) overflows before sinh does */
    double h = te_exp(ax * 0.5);
    v = (0.5 * h) * h;
  } else {
    double e = te_exp(ax);
    v = 0.5 * (e - 1.0 / e);
  }
  return x < 0.0 ? -v : v;
}

double te_cosh(double x) {
  double ax = te_abs(x);
  if (te_isnan(x)) return x;
  if (ax > 700.0) {
    double h = te_exp(ax * 0.5);
    return (0.5 * h) * h;
  }
  {
    double e = te_exp(ax);
    return 0.5 * (e + 1.0 / e);
  }
}

double te_tanh(double x) {
  double ax = te_abs(x), v;
  if (te_isnan(x)) return x;
  if (ax < 0.5) return te_sinh(x) / te_cosh(x);
  if (ax > 22.0) return x < 0.0 ? -1.0 : 1.0;
  {
    double e = te_exp(-2.0 * ax);
    v = (1.0 - e) / (1.0 + e);
  }
  return x < 0.0 ? -v : v;
}

double te_asinh(double x) {
  double ax = te_abs(x), v;
  if (!te_isfinite(x)) return x;
  if (ax > 1e8) {
    v = te_log(ax) + 0.69314718055994530942; /* x^2 + 1 would overflow */
  } else {
    v = te_log1p(ax + ax * ax / (1.0 + te_sqrt(1.0 + ax * ax)));
  }
  return x < 0.0 ? -v : v;
}

double te_acosh(double x) {
  if (te_isnan(x) || x < 1.0) return TE_NAN;
  if (te_isinf(x)) return x;
  if (x > 1e8) return te_log(x) + 0.69314718055994530942;
  {
    double t = x - 1.0;
    return te_log1p(t + te_sqrt(t * (x + 1.0)));
  }
}

double te_atanh(double x) {
  double ax = te_abs(x), v;
  if (te_isnan(x) || ax > 1.0) return TE_NAN;
  if (ax == 1.0) return x < 0.0 ? -TE_INF : TE_INF;
  v = 0.5 * te_log1p(2.0 * ax / (1.0 - ax));
  return x < 0.0 ? -v : v;
}

double te_sinc(double x) {
  if (x == 0.0) return 1.0;
  return te_sin(x) / x;
}

double te_cbrt(double x) {
  double ax = te_abs(x);
  if (!te_isfinite(x) || x == 0.0) return x;
  {
    double r = te_exp(te_log(ax) / 3.0);
    r = r - (r * r * r - ax) / (3.0 * r * r); /* one Newton step */
    return x < 0.0 ? -r : r;
  }
}

double te_hypot(double a, double b) {
  double aa = te_abs(a), bb = te_abs(b), t;
  if (te_isinf(a) || te_isinf(b)) return TE_INF; /* even with NaN (C99) */
  if (te_isnan(a) || te_isnan(b)) return TE_NAN;
  if (aa < bb) { t = aa; aa = bb; bb = t; }
  if (aa == 0.0) return 0.0;
  t = bb / aa;
  return aa * te_sqrt(1.0 + t * t);
}

/* ---------- log-gamma for large arguments (Stirling) ---------- */

static double te_lgamma_stirling(double z) {
  /* z >= 10 */
  double inv = 1.0 / z;
  double inv2 = inv * inv;
  return (z - 0.5) * te_log(z) - z + 0.5 * te_log(2.0 * TE_PI) +
         inv * (1.0 / 12.0 -
                inv2 * (1.0 / 360.0 -
                        inv2 * (1.0 / 1260.0 -
                                inv2 * (1.0 / 1680.0 - inv2 * (1.0 / 1188.0)))));
}

/* ---------- digamma ---------- */

double te_digamma(double x) {
  double result = 0.0;
  if (te_isnan(x)) return x;
  if (x <= 0.0) {
    double s = te_sinpi(x);
    if (s == 0.0) return TE_NAN; /* poles at non-positive integers */
    return te_digamma(1.0 - x) - TE_PI * te_cospi(x) / s;
  }
  while (x < 10.0) {
    result -= 1.0 / x;
    x += 1.0;
  }
  {
    double r = 1.0 / (x * x);
    result += te_log(x) - 0.5 / x -
              r * (1.0 / 12.0 -
                   r * (1.0 / 120.0 -
                        r * (1.0 / 252.0 -
                             r * (1.0 / 240.0 - r * (1.0 / 132.0)))));
  }
  return result;
}

/* ---------- beta ---------- */

double te_beta(double a, double b) {
  if (te_isnan(a) || te_isnan(b) || a <= 0.0 || b <= 0.0) return TE_NAN;
  if (a + b < 170.0) return te_gamma(a) * te_gamma(b) / te_gamma(a + b);
  return te_exp_lgamma_combination(te_lgamma(a), te_lgamma(b), te_lgamma(a + b));
}

/* ---------- incomplete gamma ---------- */

static int te_ln_gamma(double x, double *out) {
  double v = te_lgamma(x);
  if (te_isnan(v) || te_abs(v) == TE_INF) return 0;
  *out = v;
  return 1;
}

/* P(a,x) by series; used when x < a+1. */
static double te_gammainc_series(double a, double x) {
  double ap = a;
  double sum = 1.0 / a;
  double del = sum;
  double gln;
  int n;
  if (!te_ln_gamma(a, &gln)) return TE_NAN;
  for (n = 0; n < 100000; n++) {
    ap += 1.0;
    del *= x / ap;
    sum += del;
    if (te_abs(del) < te_abs(sum) * 1e-17) return sum * te_exp(-x + a * te_log(x) - gln);
  }
  return TE_NAN; /* did not converge */
}

/* Q(a,x) by continued fraction (Lentz); used when x >= a+1. */
static double te_gammainc_cf(double a, double x) {
  const double tiny = 1e-300;
  double b = x + 1.0 - a;
  double c = 1.0 / tiny;
  double d = 1.0 / b;
  double h = d;
  double gln;
  int i;
  if (!te_ln_gamma(a, &gln)) return TE_NAN;
  for (i = 1; i <= 1000; i++) {
    double an = -(double)i * ((double)i - a);
    double del;
    b += 2.0;
    d = an * d + b;
    if (te_abs(d) < tiny) d = tiny;
    c = b + an / c;
    if (te_abs(c) < tiny) c = tiny;
    d = 1.0 / d;
    del = d * c;
    h *= del;
    if (te_abs(del - 1.0) <= 4.4e-16) return te_exp(-x + a * te_log(x) - gln) * h;
  }
  return TE_NAN; /* did not converge */
}

double te_gammainc_p(double a, double x) {
  if (te_isnan(a) || te_isnan(x) || te_isinf(a) || x < 0.0 || a <= 0.0) return TE_NAN;
  if (te_isinf(x)) return 1.0;
  if (x == 0.0) return 0.0;
  if (x < a + 1.0) return te_gammainc_series(a, x);
  return 1.0 - te_gammainc_cf(a, x);
}

double te_gammainc_q(double a, double x) {
  if (te_isnan(a) || te_isnan(x) || te_isinf(a) || x < 0.0 || a <= 0.0) return TE_NAN;
  if (te_isinf(x)) return 0.0;
  if (x == 0.0) return 1.0;
  if (x < a + 1.0) return 1.0 - te_gammainc_series(a, x);
  return te_gammainc_cf(a, x);
}

/* ---------- erf / erfc / erfinv ---------- */

#define TE_2_SQRTPI 1.12837916709551257390

double te_erf(double x) {
  double ax, x2, term, sum;
  int n;
  if (te_isnan(x)) return x;
  ax = te_abs(x);
  if (ax == TE_INF) return x > 0.0 ? 1.0 : -1.0;
  if (ax < 1.6) {
    x2 = x * x;
    term = x;
    sum = x;
    for (n = 1; n < 100; n++) {
      term = -term * x2 * (2.0 * n - 1.0) / ((double)n * (2.0 * n + 1.0));
      sum += term;
      if (te_abs(term) < 1e-19 * te_abs(sum)) break;
    }
    return TE_2_SQRTPI * sum;
  }
  {
    double value = 1.0 - te_gammainc_q(0.5, ax * ax);
    return x > 0.0 ? value : -value;
  }
}

double te_erfc(double x) {
  double ax;
  if (te_isnan(x)) return x;
  ax = te_abs(x);
  if (ax == TE_INF) return x > 0.0 ? 0.0 : 2.0;
  if (ax < 1.6) return 1.0 - te_erf(x);
  {
    double q = te_gammainc_q(0.5, x * x);
    return x > 0.0 ? q : 2.0 - q;
  }
}

/* Newton on erfinv using erfc for the tail, so large |x| stays accurate. */
double te_erfinv(double p) {
  double x, err;
  int i;
  if (p <= -1.0 || p >= 1.0) {
    if (p == 1.0) return TE_INF;
    if (p == -1.0) return -TE_INF;
    return TE_NAN;
  }
  if (p == 0.0) return 0.0;
  /* initial guess: Giles' approximation */
  {
    double w = -te_log((1.0 - p) * (1.0 + p));
    double g;
    if (w < 5.0) {
      w -= 2.5;
      g = 2.81022636e-08;
      g = 3.43273939e-07 + g * w;
      g = -3.5233877e-06 + g * w;
      g = -4.39150654e-06 + g * w;
      g = 0.00021858087 + g * w;
      g = -0.00125372503 + g * w;
      g = -0.00417768164 + g * w;
      g = 0.246640727 + g * w;
      g = 1.50140941 + g * w;
    } else {
      double s = te_sqrt(w) - 3.0;
      g = -0.000200214257;
      g = 0.000100950558 + g * s;
      g = 0.00134934322 + g * s;
      g = -0.00367342844 + g * s;
      g = 0.00573950773 + g * s;
      g = -0.0076224613 + g * s;
      g = 0.00943887047 + g * s;
      g = 1.00167406 + g * s;
      g = 2.83297682 + g * s;
    }
    x = g * p;
  }
  if (te_abs(p) > 0.5) {
    /* Tail: erfc(|x|) = 1 - |p| is exact (Sterbenz), erf(x) - p is not. */
    double q = 1.0 - te_abs(p);
    double ax = te_abs(x);
    for (i = 0; i < 40; i++) {
      double derivative = -TE_2_SQRTPI * te_exp(-ax * ax);
      double step = (te_erfc(ax) - q) / derivative;
      ax -= step;
      if (te_abs(step) <= 1e-16 * ax) break;
    }
    return p < 0.0 ? -ax : ax;
  }
  for (i = 0; i < 40; i++) {
    double derivative, step;
    err = te_erf(x) - p;
    derivative = TE_2_SQRTPI * te_exp(-x * x);
    step = err / derivative;
    x -= step;
    if (te_abs(step) <= 1e-16 * te_abs(x) + 1e-300) break;
  }
  return x;
}

/* ---------- incomplete beta ---------- */

static double te_betacf(double a, double b, double x) {
  const double tiny = 1e-300;
  double qab = a + b, qap = a + 1.0, qam = a - 1.0;
  double c = 1.0;
  double d = 1.0 - qab * x / qap;
  double h;
  int m;
  if (te_abs(d) < tiny) d = tiny;
  d = 1.0 / d;
  h = d;
  for (m = 1; m <= 500; m++) {
    int m2 = 2 * m;
    double aa = (double)m * (b - (double)m) * x /
                ((qam + (double)m2) * (a + (double)m2));
    double del;
    d = 1.0 + aa * d;
    if (te_abs(d) < tiny) d = tiny;
    c = 1.0 + aa / c;
    if (te_abs(c) < tiny) c = tiny;
    d = 1.0 / d;
    h *= d * c;
    /* second step: aa = -(a+m)(a+b+m)x / ((a+2m)(a+2m+1)) */
    aa = -((double)m + a) * ((double)m + qab) * x /
         ((a + (double)m2) * (qap + (double)m2));
    d = 1.0 + aa * d;
    if (te_abs(d) < tiny) d = tiny;
    c = 1.0 + aa / c;
    if (te_abs(c) < tiny) c = tiny;
    d = 1.0 / d;
    del = d * c;
    h *= del;
    if (te_abs(del - 1.0) <= 4.4e-16) return h;
  }
  return TE_NAN; /* did not converge */
}

double te_betainc(double a, double b, double x) {
  double bt;
  if (te_isnan(a) || te_isnan(b) || te_isnan(x) || te_isinf(a) || te_isinf(b)) return TE_NAN;
  if (a <= 0.0 || b <= 0.0 || x < 0.0 || x > 1.0) return TE_NAN;
  if (x == 0.0) return 0.0;
  if (x == 1.0) return 1.0;
  bt = te_exp(te_lgamma(a + b) - te_lgamma(a) - te_lgamma(b) +
              a * te_log(x) + b * te_log(1.0 - x));
  if (x < (a + 1.0) / (a + b + 2.0)) return bt * te_betacf(a, b, x) / a;
  return 1.0 - bt * te_betacf(b, a, 1.0 - x) / b;
}

/* ---------- Riemann zeta (Euler–Maclaurin) ---------- */

double te_zeta(double s) {
  const int N = 20;
  double sum = 0.0;
  double Ns, t;
  int n;
  if (te_isnan(s)) return s;
  if (s == 1.0) return TE_INF;
  if (te_isinf(s)) return s > 0.0 ? 1.0 : TE_NAN;
  if (s > 50.0) return 1.0 + te_pow(2.0, -s) + te_pow(3.0, -s); /* exact to rounding */
  if (s < -0.5) {
    /* zeta(s) = 2^s pi^(s-1) sin(pi s/2) Gamma(1-s) zeta(1-s), evaluated in
     * log space so huge Gamma and tiny powers never meet as 0·inf. */
    double sp = te_sinpi(0.5 * s);
    double z1 = te_zeta(1.0 - s);
    double logmag;
    if (sp == 0.0) return 0.0; /* trivial zeros at negative even integers */
    logmag = s * 0.69314718055994530942 + (s - 1.0) * 1.14472988584940017414 +
             te_lgamma(1.0 - s) + te_log(te_abs(sp)) + te_log(te_abs(z1));
    {
      double v = te_exp(logmag);
      int negative = (sp < 0.0) != (z1 < 0.0);
      return negative ? -v : v;
    }
  }
  for (n = 1; n < N; n++) sum += te_pow((double)n, -s);
  Ns = te_pow((double)N, -s);
  sum += Ns * (0.5 + (double)N / (s - 1.0));
  /* Euler–Maclaurin corrections:
   *   Σ_k B_{2k}/(2k)! · (s)_{2k-1} · N^{-s-2k+1}
   * with B2=1/6, B4=-1/30, B6=1/42, B8=-1/30, B10=5/66. */
  {
    double rising = s;          /* (s)_{2k-1} built up as k grows */
    double Np = Ns / (double)N; /* N^{-s-1} */
    double invN2 = 1.0 / ((double)N * (double)N);
    sum += (1.0 / 6.0) / 2.0 * rising * Np;          /* B2/2! */
    rising *= (s + 1.0) * (s + 2.0);
    Np *= invN2;
    sum += (-1.0 / 30.0) / 24.0 * rising * Np;       /* B4/4! */
    rising *= (s + 3.0) * (s + 4.0);
    Np *= invN2;
    sum += (1.0 / 42.0) / 720.0 * rising * Np;       /* B6/6! */
    rising *= (s + 5.0) * (s + 6.0);
    Np *= invN2;
    sum += (-1.0 / 30.0) / 40320.0 * rising * Np;    /* B8/8! */
    rising *= (s + 7.0) * (s + 8.0);
    Np *= invN2;
    sum += (5.0 / 66.0) / 3628800.0 * rising * Np;   /* B10/10! */
  }
  (void)t;
  return sum;
}

/* ---------- Lambert W ---------- */

/* Halley iteration on w e^w = x. The result is verified: if the residual is
 * not at rounding level the function declines (NaN) instead of returning an
 * unconverged iterate. */
static double te_lambert_iterate(double w, double x) {
  int i;
  if (te_isinf(x)) return x;
  for (i = 0; i < 100; i++) {
    double ew = te_exp(w);
    double f = w * ew - x;
    double denominator = ew * (w + 1.0) - (w + 2.0) * f / (2.0 * w + 2.0);
    double step;
    if (denominator == 0.0 || te_isnan(denominator)) break;
    step = f / denominator;
    w -= step;
    if (te_abs(step) <= 1e-15 * te_abs(w) + 1e-300) break;
  }
  {
    /* verify in relative terms of x; near the branch point the residual is
     * dominated by the rounding of x itself */
    double residual = te_abs(w * te_exp(w) - x);
    if (!(residual <= 1e-13 * te_abs(x) + 1e-300)) return TE_NAN;
  }
  return w;
}

double te_lambert_w(double x) {
  if (x < -1.0 / TE_E) return TE_NAN;
  if (x == 0.0) return 0.0;
  if (x == -1.0 / TE_E) return -1.0;
  if (x > 0.0) {
    double w = (x > 3.0) ? te_log(x) - te_log(te_log(x)) : x * (1.0 - x);
    if (w <= 0.0) w = 1e-6;
    return te_lambert_iterate(w, x);
  }
  {
    /* -1/e < x < 0, principal branch */
    double p = te_sqrt(2.0 * (TE_E * x + 1.0));
    double w = -1.0 + p - p * p / 3.0 + 11.0 * p * p * p / 72.0;
    return te_lambert_iterate(w, x);
  }
}

double te_lambert_wm1(double x) {
  double w;
  if (te_isnan(x) || x < -1.0 / TE_E || x >= 0.0) return TE_NAN;
  if (x == -1.0 / TE_E) return -1.0;
  if (x < -0.25) {
    /* near the branch point: series in p = -sqrt(2(1 + e x)) */
    double p = te_sqrt(2.0 * (TE_E * x + 1.0));
    w = -1.0 - p - p * p / 3.0 - 11.0 * p * p * p / 72.0;
  } else {
    /* x -> 0-: W ~ L1 - L2 + L2/L1 with L1 = ln(-x), L2 = ln(-L1) */
    double l1 = te_log(-x), l2 = te_log(-l1);
    w = l1 - l2 + l2 / l1;
  }
  return te_lambert_iterate(w, x);
}

/* ---------- exponential integrals ---------- */

double te_ei(double x) {
  if (te_isnan(x)) return x;
  if (x == 0.0) return -TE_INF;
  if (x == TE_INF) return TE_INF;
  if (x == -TE_INF) return 0.0;
  if (x < 0.0) return -te_e1(-x);
  if (x < 30.0) {
    double sum = 0.0, term = 1.0;
    int n;
    for (n = 1; n < 300; n++) {
      double add;
      term *= x / (double)n;
      add = term / (double)n;
      sum += add;
      if (te_abs(add) < 1e-19 * te_abs(sum)) break;
    }
    return TE_EULER + te_log(x) + sum;
  }
  {
    double inv = 1.0 / x, term = 1.0, sum = 1.0;
    int k;
    for (k = 1; k < 16; k++) {
      term *= (double)k * inv;
      sum += term;
      if (te_abs(term) < 1e-19 * te_abs(sum)) break;
    }
    return te_exp(x) * inv * sum;
  }
}

double te_e1(double x) {
  if (te_isnan(x) || x < 0.0) return TE_NAN; /* complex for x < 0 */
  if (x == 0.0) return TE_INF;
  if (x == TE_INF) return 0.0;
  if (x < 1.0) {
    double sum = 0.0, term = 1.0;
    int n;
    for (n = 1; n < 300; n++) {
      double add;
      term *= -x / (double)n;
      add = term / (double)n;
      sum += add;
      if (te_abs(add) < 1e-19 * te_abs(sum)) break;
    }
    return -TE_EULER - te_log(x) - sum;
  }
  {
    /* Lentz continued fraction: E1(x) = e^-x * h */
    const double tiny = 1e-300;
    double b = x + 1.0;
    double c = 1.0 / tiny;
    double d = 1.0 / b;
    double h = d;
    int i;
    for (i = 1; i <= 5000; i++) {
      double a = -(double)i * (double)i;
      double del;
      b += 2.0;
      d = 1.0 / (a * d + b);
      c = b + a / c;
      del = d * c;
      h *= del;
      if (te_abs(del - 1.0) <= 4.4e-16) return te_exp(-x) * h;
    }
    return TE_NAN; /* did not converge */
  }
}

double te_li(double x) {
  if (te_isnan(x) || x < 0.0) return TE_NAN;
  if (x == 0.0) return 0.0;
  if (x == 1.0) return -TE_INF;
  return te_ei(te_log(x));
}

/* ---------- sine / cosine integrals ---------- */

/* Si and Ci together. |x| <= 2: power series. |x| > 2: Lentz evaluation of
 * the complex continued fraction for E1(ix) (Numerical Recipes, cisi), which
 * is accurate to ~1e-15 with no cancellation. */
static int te_sici(double x, double *si, double *ci) {
  double t = te_abs(x);
  if (te_isnan(x)) return 0;
  if (t == TE_INF) {
    *si = x > 0.0 ? TE_PI / 2.0 : -TE_PI / 2.0;
    *ci = 0.0;
    return 1;
  }
  if (t == 0.0) {
    *si = 0.0;
    *ci = -TE_INF;
    return 1;
  }
  if (t > 2.0) {
    const double tiny = 1e-300;
    double br = 1.0, bi = t;      /* b = 1 + i t */
    double cr = 1.0 / tiny, ci2 = 0.0;
    double dr, di, hr, hi, den;
    int i, converged = 0;
    den = br * br + bi * bi;      /* d = h = 1 / b */
    dr = br / den;
    di = -bi / den;
    hr = dr;
    hi = di;
    for (i = 2; i <= 1000; i++) {
      double a = -(double)(i - 1) * (double)(i - 1);
      double xr, xi, delr, deli, tr, ti;
      br += 2.0;
      /* d = 1 / (a d + b) */
      xr = a * dr + br;
      xi = a * di + bi;
      den = xr * xr + xi * xi;
      dr = xr / den;
      di = -xi / den;
      /* c = b + a / c */
      den = cr * cr + ci2 * ci2;
      tr = br + a * cr / den;
      ti = bi - a * ci2 / den;
      cr = tr;
      ci2 = ti;
      /* del = c d ; h *= del */
      delr = cr * dr - ci2 * di;
      deli = cr * di + ci2 * dr;
      tr = hr * delr - hi * deli;
      ti = hr * deli + hi * delr;
      hr = tr;
      hi = ti;
      if (te_abs(delr - 1.0) + te_abs(deli) <= 4.4e-16) { converged = 1; break; }
    }
    if (!converged) return 0;
    {
      double c = te_cos(t), s = te_sin(t);
      double fr, fi;
      if (te_isnan(c) || te_isnan(s)) return 0;
      /* h *= (cos t - i sin t) */
      fr = c * hr + s * hi;
      fi = c * hi - s * hr;
      *ci = -fr;
      *si = TE_PI / 2.0 + fi;
    }
  } else {
    double sum_s = 0.0, sum_c = 0.0, term = 1.0;
    int k;
    for (k = 1; k < 100; k++) {
      term *= t / (double)k; /* t^k / k! */
      if (k % 2 == 1) {
        double add = ((k / 2) % 2 == 0 ? 1.0 : -1.0) * term / (double)k;
        sum_s += add;
      } else {
        double add = ((k / 2) % 2 == 1 ? -1.0 : 1.0) * term / (double)k;
        sum_c += add;
      }
      if (term < 1e-19) break;
    }
    *si = sum_s;
    *ci = TE_EULER + te_log(t) + sum_c;
  }
  if (x < 0.0) *si = -*si;
  return 1;
}

double te_si(double x) {
  double si, ci;
  if (!te_sici(x, &si, &ci)) return TE_NAN;
  return si;
}

double te_ci(double x) {
  double si, ci;
  if (te_isnan(x) || x < 0.0) return TE_NAN; /* complex for x < 0 */
  if (!te_sici(x, &si, &ci)) return TE_NAN;
  return ci;
}

/* ---------- Airy ---------- */

/* Ai(x) = c1 f(x) - c2 g(x), Bi(x) = sqrt(3)(c1 f(x) + c2 g(x)) */
static void te_airy_series(double x, double *f, double *g) {
  double x3 = x * x * x;
  double fk = 1.0, gk = x, fsum = 1.0, gsum = x;
  int k;
  for (k = 1; k < 200; k++) {
    fk *= 3.0 * ((double)k - 2.0 / 3.0) * x3 /
          (((3.0 * k - 2.0) * (3.0 * k - 1.0)) * (3.0 * k));
    gk *= 3.0 * ((double)k - 1.0 / 3.0) * x3 /
          (((3.0 * k - 1.0) * (3.0 * k)) * (3.0 * k + 1.0));
    fsum += fk;
    gsum += gk;
    if (te_abs(fk) < 1e-19 * te_abs(fsum) && te_abs(gk) < 1e-19 * te_abs(gsum)) break;
  }
  *f = fsum;
  *g = gsum;
}

static void te_airy_constants(double *c1, double *c2) {
  *c1 = 1.0 / (te_pow(3.0, 2.0 / 3.0) * te_gamma(2.0 / 3.0));
  *c2 = 1.0 / (te_pow(3.0, 1.0 / 3.0) * te_gamma(1.0 / 3.0));
}

/* |x| < 1: the power series (no significant cancellation there).
 * |x| >= 1: exact Bessel identities with z = (2/3)|x|^(3/2):
 *   Ai(x)  = (1/pi) sqrt(x/3) K_{1/3}(z)
 *   Bi(x)  = sqrt(x/3) (I_{-1/3}(z) + I_{1/3}(z))
 *   Ai(-x) = (sqrt(x)/3) (J_{1/3}(z) + J_{-1/3}(z))
 *   Bi(-x) = sqrt(x/3) (J_{-1/3}(z) - J_{1/3}(z))
 * which inherit the Bessel module's accuracy and its declines. */
double te_airy_ai(double x) {
  double c1, c2, z;
  if (te_isnan(x)) return x;
  if (x == TE_INF) return 0.0;
  if (x == -TE_INF) return 0.0;
  if (te_abs(x) < 1.0) {
    double f, g;
    te_airy_constants(&c1, &c2);
    te_airy_series(x, &f, &g);
    return c1 * f - c2 * g;
  }
  z = 2.0 / 3.0 * te_pow(te_abs(x), 1.5);
  if (x < 0.0 && !(z <= TE_TRIG_MAX)) return TE_NAN; /* phase unresolvable */
  if (x > 0.0) return te_sqrt(x / 3.0) * te_bessel_k(1.0 / 3.0, z) / TE_PI;
  return te_sqrt(-x) / 3.0 * (te_bessel_j(1.0 / 3.0, z) + te_bessel_j(-1.0 / 3.0, z));
}

double te_airy_bi(double x) {
  double c1, c2, z;
  if (te_isnan(x)) return x;
  if (x == TE_INF) return TE_INF;
  if (x == -TE_INF) return 0.0;
  if (te_abs(x) < 1.0) {
    double f, g;
    te_airy_constants(&c1, &c2);
    te_airy_series(x, &f, &g);
    return te_sqrt(3.0) * (c1 * f + c2 * g);
  }
  z = 2.0 / 3.0 * te_pow(te_abs(x), 1.5);
  if (x < 0.0 && !(z <= TE_TRIG_MAX)) return TE_NAN; /* phase unresolvable */
  if (x > 0.0) {
    return te_sqrt(x / 3.0) * (te_bessel_i(-1.0 / 3.0, z) + te_bessel_i(1.0 / 3.0, z));
  }
  return te_sqrt(-x / 3.0) * (te_bessel_j(-1.0 / 3.0, z) - te_bessel_j(1.0 / 3.0, z));
}

/* j_v(x) = sqrt(pi)/2 (x/2)^v / Gamma(v + 3/2) · sum_k (-x^2/4)^k / (k! (v+3/2)_k),
 * x >= 0. Forming the lead in log space keeps tiny-x values from
 * underflowing the way sqrt(pi/2x)·J_{v+1/2}(x) does. NaN if not converged. */
static double te_sph_j_series(double v, double x) {
  double q = 0.25 * x * x, lead, total, term;
  int k;
  if (x == 0.0) return v == 0.0 ? 1.0 : (v > 0.0 ? 0.0 : TE_NAN);
  if (v + 1.5 <= 0.0) return TE_NAN;
  lead = te_exp(0.5 * te_log(TE_PI) - 0.69314718055994530942 + v * te_log(0.5 * x) - te_lgamma(v + 1.5));
  total = lead;
  term = lead;
  if (lead == 0.0) return 0.0;
  for (k = 0; k < 4000; k++) {
    term = term * (-q) / (((double)k + 1.0) * (v + 1.5 + (double)k));
    total += term;
    if (te_abs(term) <= 1e-17 * te_abs(total)) return total;
  }
  return TE_NAN;
}

/* ---------- spherical Bessel ----------
 * Hankel functions H1/H2 are complex; the scalar API deliberately omits them.
 * The real parts are available as besselj/bessely.
 */

double te_sph_bessel_j(double n, double x) {
  double v;
  if (te_isnan(n) || te_isnan(x) || te_isinf(n)) return TE_NAN;
  if (x == 0.0) return n == 0.0 ? 1.0 : (n > 0.0 ? 0.0 : TE_NAN);
  if (te_isinf(x)) return 0.0;
  if (x < 0.0) {
    if (!te_is_integer(n)) return TE_NAN;
    v = te_sph_bessel_j(n, -x);
    return te_is_odd(n) ? -v : v; /* j_n(-x) = (-1)^n j_n(x) */
  }
  if (te_is_integer(n) && n < 0.0) { /* j_{-k-1} = (-1)^(k+1) y_k */
    double k = -n - 1.0, y = te_sph_bessel_y(k, x);
    return te_is_odd(k) ? y : -y;
  }
  if (x <= TE_ASYM_MIN_X && n + 1.5 > 0.0) return te_sph_j_series(n, x);
  return te_sqrt(TE_PI / (2.0 * x)) * te_bessel_j(n + 0.5, x);
}

double te_sph_bessel_y(double n, double x) {
  double v;
  if (te_isnan(n) || te_isnan(x) || te_isinf(n)) return TE_NAN;
  if (x == 0.0) return n >= 0.0 ? -TE_INF : TE_NAN;
  if (te_isinf(x)) return 0.0;
  if (x < 0.0) {
    if (!te_is_integer(n)) return TE_NAN;
    v = te_sph_bessel_y(n, -x);
    return te_is_odd(n) ? v : -v; /* y_n(-x) = (-1)^(n+1) y_n(x) */
  }
  if (te_is_integer(n) && n < 0.0) { /* y_{-k-1} = (-1)^k j_k (avoids underflow) */
    double k = -n - 1.0, j = te_sph_bessel_j(k, x);
    return te_is_odd(k) ? -j : j;
  }
  return te_sqrt(TE_PI / (2.0 * x)) * te_bessel_y(n + 0.5, x);
}

/* ---------- orthogonal polynomials (integer order recurrences) ---------- */

static int te_int_order(double n, int *out) {
  if (!te_is_integer(n)) return 0;
  if (te_abs(n) > 200.0) return 0;
  *out = (int)te_round(n);
  return 1;
}

double te_legendre_p(double n, double x) {
  int k, order;
  if (te_isnan(x)) return x;
  double p0 = 1.0, p1 = x;
  if (!te_int_order(n, &order) || order < 0) return TE_NAN;
  if (order == 0) return 1.0;
  if (order == 1) return x;
  for (k = 1; k < order; k++) {
    double p2 = ((2.0 * k + 1.0) * x * p1 - (double)k * p0) / ((double)k + 1.0);
    p0 = p1;
    p1 = p2;
  }
  /* an intermediate overflow does not mean the true value overflows */
  return te_isfinite(p1) ? p1 : TE_NAN;
}

double te_chebyshev_t(double n, double x) {
  int k, order;
  if (te_isnan(x)) return x;
  double t0 = 1.0, t1 = x;
  if (!te_int_order(n, &order) || order < 0) return TE_NAN;
  if (order == 0) return 1.0;
  if (order == 1) return x;
  for (k = 1; k < order; k++) {
    double t2 = 2.0 * x * t1 - t0;
    t0 = t1;
    t1 = t2;
  }
  /* an intermediate overflow does not mean the true value overflows */
  return te_isfinite(t1) ? t1 : TE_NAN;
}

double te_chebyshev_u(double n, double x) {
  int k, order;
  if (te_isnan(x)) return x;
  double u0 = 1.0, u1 = 2.0 * x;
  if (!te_int_order(n, &order) || order < 0) return TE_NAN;
  if (order == 0) return 1.0;
  if (order == 1) return 2.0 * x;
  for (k = 1; k < order; k++) {
    double u2 = 2.0 * x * u1 - u0;
    u0 = u1;
    u1 = u2;
  }
  /* an intermediate overflow does not mean the true value overflows */
  return te_isfinite(u1) ? u1 : TE_NAN;
}

double te_hermite_h(double n, double x) {
  int k, order;
  if (te_isnan(x)) return x;
  double h0 = 1.0, h1 = 2.0 * x;
  if (!te_int_order(n, &order) || order < 0) return TE_NAN;
  if (order == 0) return 1.0;
  if (order == 1) return 2.0 * x;
  for (k = 1; k < order; k++) {
    double h2 = 2.0 * x * h1 - 2.0 * (double)k * h0;
    h0 = h1;
    h1 = h2;
  }
  /* an intermediate overflow does not mean the true value overflows */
  return te_isfinite(h1) ? h1 : TE_NAN;
}

double te_laguerre_l(double n, double x) {
  int k, order;
  if (te_isnan(x)) return x;
  double l0 = 1.0, l1 = 1.0 - x;
  if (!te_int_order(n, &order) || order < 0) return TE_NAN;
  if (order == 0) return 1.0;
  if (order == 1) return 1.0 - x;
  for (k = 1; k < order; k++) {
    double l2 = ((2.0 * k + 1.0 - x) * l1 - (double)k * l0) / ((double)k + 1.0);
    l0 = l1;
    l1 = l2;
  }
  /* an intermediate overflow does not mean the true value overflows */
  return te_isfinite(l1) ? l1 : TE_NAN;
}

/* ---------- elliptic integrals and Jacobi functions ---------- */

double te_ellip_k(double m) {
  double a = 1.0, b;
  int i;
  if (te_isnan(m) || m > 1.0) return TE_NAN; /* complex for m > 1 */
  if (m == 1.0) return TE_INF;
  if (m == -TE_INF) return 0.0;
  b = te_sqrt(1.0 - m);
  for (i = 0; i < 80; i++) {
    double an = 0.5 * (a + b);
    double bn = te_sqrt(a * b);
    a = an;
    b = bn;
    if (te_abs(a - b) <= 4.4e-16 * a) return TE_PI / (2.0 * a);
  }
  return TE_NAN;
}

double te_ellip_e(double m) {
  double a = 1.0, b, c, sum, pow2 = 1.0;
  int i;
  if (te_isnan(m) || m > 1.0 || te_isinf(m)) return TE_NAN;
  if (m == 1.0) return 1.0;
  b = te_sqrt(1.0 - m);
  sum = 0.5 * m; /* 2^-1 c0^2 with c0^2 = m (also valid for m < 0) */
  for (i = 0; i < 80; i++) {
    double an = 0.5 * (a + b);
    double bn = te_sqrt(a * b);
    c = 0.5 * (a - b);
    a = an;
    b = bn;
    pow2 *= 2.0;
    sum += pow2 * 0.5 * c * c;
    if (te_abs(c) <= 4.4e-16 * a) return TE_PI / (2.0 * a) * (1.0 - sum);
  }
  return TE_NAN;
}

/* Inverse-AGM Jacobi elliptic functions (descending Landen). */
/* Inverse-AGM Jacobi elliptic functions (descending Landen, A&S 16.4).
 * dn = cos(phi0) / cos(phi1 - phi0) avoids sqrt(1 - m sn^2), which cancels
 * catastrophically as m -> 1. */
static void te_jacobi(double u, double m, double *sn, double *cn, double *dn) {
  double a[64], b[64], c[64];
  int n = 0, i;
  double phi, previous;
  a[0] = 1.0;
  b[0] = te_sqrt(1.0 - m);
  c[0] = te_sqrt(m);
  while (n < 60) {
    double an = 0.5 * (a[n] + b[n]);
    double bn = te_sqrt(a[n] * b[n]);
    double cn2 = 0.5 * (a[n] - b[n]);
    n++;
    a[n] = an;
    b[n] = bn;
    c[n] = cn2;
    if (te_abs(cn2) <= 4.4e-16 * an) break;
  }
  phi = te_pow(2.0, (double)n) * a[n] * u;
  previous = phi;
  for (i = n; i > 0; i--) {
    double argument = c[i] / a[i] * te_sin(phi);
    if (argument > 1.0) argument = 1.0;
    if (argument < -1.0) argument = -1.0;
    previous = phi;
    phi = 0.5 * (phi + te_asin(argument));
  }
  *sn = te_sin(phi);
  *cn = te_cos(phi);
  *dn = (n == 0) ? 1.0 : *cn / te_cos(previous - phi);
}

/* Domain guard + the m = 1 limit (sn = tanh, cn = dn = sech). */
static int te_jacobi_checked(double u, double m, double *sn, double *cn, double *dn) {
  if (te_isnan(u) || te_isnan(m) || te_isinf(u) || m < 0.0 || m > 1.0) return 0;
  if (te_abs(u) > 1e8) return 0; /* argument rounding exceeds ~1e-8 there */
  if (m == 1.0) {
    double ch = te_cosh(u);
    *sn = te_tanh(u);
    *cn = 1.0 / ch;
    *dn = 1.0 / ch;
    return 1;
  }
  te_jacobi(u, m, sn, cn, dn);
  return !(te_isnan(*sn) || te_isnan(*cn) || te_isnan(*dn));
}

double te_jacobi_sn(double u, double m) {
  double sn, cn, dn;
  if (!te_jacobi_checked(u, m, &sn, &cn, &dn)) return TE_NAN;
  return sn;
}

double te_jacobi_cn(double u, double m) {
  double sn, cn, dn;
  if (!te_jacobi_checked(u, m, &sn, &cn, &dn)) return TE_NAN;
  return cn;
}

double te_jacobi_dn(double u, double m) {
  double sn, cn, dn;
  if (!te_jacobi_checked(u, m, &sn, &cn, &dn)) return TE_NAN;
  return dn;
}

/* ---------- combinatorial helpers ---------- */

double te_factorial(double n) {
  if (te_isnan(n)) return n;
  if (n < 0.0 && te_is_integer(n)) return TE_NAN; /* pole */
  if (te_is_integer(n) && n <= 170.0) {
    double result = 1.0;
    double i;
    for (i = 2.0; i <= n; i += 1.0) result *= i;
    return result;
  }
  return te_gamma(n + 1.0);
}

/* exp(la + lb - lc) with a rounding-error estimate: the lgamma path loses
 * absolute accuracy proportional to the magnitudes, so it declines (NaN)
 * when that error would exceed ~1e-10 relative. */
static double te_exp_lgamma_combination(double la, double lb, double lc) {
  double bound = (te_abs(la) + te_abs(lb) + te_abs(lc)) * 4.4e-16;
  if (bound > 1e-10) return TE_NAN;
  return te_exp(la + lb - lc);
}

double te_binom(double n, double k) {
  double result = 1.0, i;
  if (te_isnan(n) || te_isnan(k) || te_isinf(n)) return TE_NAN;
  if (!te_is_integer(k)) return TE_NAN; /* real k is not supported */
  if (k < 0.0) return 0.0;
  if (te_is_integer(n) && n >= 0.0) {
    if (k > n) return 0.0;
    if (k > n - k) k = n - k; /* symmetry: fewer, exact steps */
    if (k > 2000.0) {
      return te_exp_lgamma_combination(te_lgamma(n + 1.0), 0.0,
                                       te_lgamma(k + 1.0) + te_lgamma(n - k + 1.0));
    }
  } else if (k > 2000.0) {
    return TE_NAN; /* generalised binomial with large k: declined */
  }
  for (i = 1.0; i <= k; i += 1.0) result = result * (n - k + i) / i;
  return result;
}

double te_npr(double n, double r) {
  double result = 1.0, i;
  if (te_isnan(n) || te_isnan(r) || te_isinf(n)) return TE_NAN;
  if (!te_is_integer(r) || r < 0.0) return TE_NAN;
  if (r > 2000.0) {
    if (!(te_is_integer(n) && n >= r)) return TE_NAN;
    return te_exp_lgamma_combination(te_lgamma(n + 1.0), 0.0, te_lgamma(n - r + 1.0));
  }
  for (i = 0.0; i < r; i += 1.0) result *= (n - i);
  return result;
}

double te_gcd(double a, double b) {
  double x, y;
  if (!te_is_integer(a) || !te_is_integer(b)) return TE_NAN;
  x = te_abs(a);
  y = te_abs(b);
  if (x > 9007199254740992.0 || y > 9007199254740992.0) return TE_NAN; /* not exact past 2^53 */
  while (y != 0.0) {
    double t = te_fmod(x, y);
    x = y;
    y = t;
  }
  return x;
}

double te_lcm(double a, double b) {
  double g = te_gcd(a, b);
  if (te_isnan(g)) return g;
  if (g == 0.0) return 0.0;
  return (te_abs(a) / g) * te_abs(b);
}
