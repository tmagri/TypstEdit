/* Native accuracy tests for the plugin's numeric core.
 *
 * Compares te_exp/te_log/te_pow/te_sin/te_cos and the Bessel/Gamma helpers
 * against the platform libm (which is what scipy wraps), over a sweep of
 * arguments. Build and run with Tools/calc-plugin/tests/run_tests.sh.
 *
 * Exit code 0 means every check passed.
 */

#include <math.h>
#include <stdio.h>

#include "../calc_math.h"

static int failures = 0;
static int checks = 0;

static double rel_error(double got, double want) {
  if (want == 0.0) return fabs(got);
  return fabs(got - want) / fabs(want);
}

static void check(const char *what, double x, double got, double want, double tolerance) {
  double err = rel_error(got, want);
  checks++;
  if (!(err <= tolerance) || isnan(got) != isnan(want)) {
    failures++;
    printf("FAIL %-22s x=% .12g got=%.17g want=%.17g relerr=%.3g (tol %.0e)\n",
           what, x, got, want, err, tolerance);
  }
}

static void check_pair(const char *what, double a, double b, double got, double want,
                       double tolerance) {
  double err = rel_error(got, want);
  checks++;
  if (!(err <= tolerance) || isnan(got) != isnan(want)) {
    failures++;
    printf("FAIL %-22s a=% .10g b=% .10g got=%.17g want=%.17g relerr=%.3g (tol %.0e)\n",
           what, a, b, got, want, err, tolerance);
  }
}

int main(void) {
  double x;

  /* exp / log over a wide but realistic range */
  for (x = -700.0; x <= 700.0; x += 0.125) {
    check("exp", x, te_exp(x), exp(x), 2e-15);
  }
  for (x = 1e-12; x < 1e12; x *= 1.37) {
    check("log", x, te_log(x), log(x), 2e-15);
  }

  /* pow: integer and fractional exponents, positive bases */
  for (x = 0.001; x < 50.0; x *= 1.11) {
    check_pair("pow(x,0.5)", x, 0.5, te_pow(x, 0.5), pow(x, 0.5), 2e-15);
    check_pair("pow(x,2.5)", x, 2.5, te_pow(x, 2.5), pow(x, 2.5), 5e-15);
    check_pair("pow(x,7)", x, 7.0, te_pow(x, 7.0), pow(x, 7.0), 1e-14);
  }

  /* sin / cos: includes large arguments that exercise range reduction */
  for (x = -40.0; x <= 40.0; x += 0.017) {
    check("sin", x, te_sin(x), sin(x), 2e-15);
    check("cos", x, te_cos(x), cos(x), 2e-15);
  }
  for (x = -2000.0; x <= 2000.0; x += 3.7) {
    check("sin-large", x, te_sin(x), sin(x), 1e-13);
    check("cos-large", x, te_cos(x), cos(x), 1e-13);
  }

  /* gamma / lgamma */
  for (x = 0.1; x <= 30.0; x += 0.037) {
    check("gamma", x, te_gamma(x), tgamma(x), 3e-13);
    check("lgamma", x, te_lgamma(x), lgamma(x), 5e-12);
  }
  for (x = -0.9; x <= -0.05; x += 0.037) {
    check("gamma-neg", x, te_gamma(x), tgamma(x), 1e-12);
  }

  /* Bessel J / Y: integer orders against libm's jn/yn.
   * Two accuracy regimes: the power series below the crossover (x <= 12) is
   * good to ~1e-12, the Hankel asymptotic just above it to ~1e-8 and
   * improves as x grows. */
  {
    int n;
    for (n = 0; n <= 5; n++) {
      for (x = 0.0; x <= 12.0; x += 0.31) {
        check_pair("bessel_j", n, x, te_bessel_j(n, x), jn(n, x), 5e-10);
        if (x > 0.0) check_pair("bessel_y", n, x, te_bessel_y(n, x), yn(n, x), 1e-9);
      }
      /* Measured worst case (orders 0-6): 7.5e-8 [12,16], 1.9e-7 (J) and
       * 2.7e-7 (Y) in [16,30], ~1e-9 beyond 30. Tolerances carry ~3x headroom. */
      for (x = 12.5; x <= 30.0; x += 0.93) {
        check_pair("bessel_j_asym", n, x, te_bessel_j(n, x), jn(n, x), 1e-6);
        check_pair("bessel_y_asym", n, x, te_bessel_y(n, x), yn(n, x), 1e-6);
      }
      for (x = 31.0; x <= 200.0; x += 5.7) {
        check_pair("bessel_j_far", n, x, te_bessel_j(n, x), jn(n, x), 1e-8);
        check_pair("bessel_y_far", n, x, te_bessel_y(n, x), yn(n, x), 1e-8);
      }
    }
  }

  /* Fractional orders against the closed half-integer forms:
   *   J_{1/2}  = sqrt(2/(pi x)) sin x
   *   Y_{1/2}  = -sqrt(2/(pi x)) cos x
   *   I_{1/2}  = sqrt(2/(pi x)) sinh x
   *   K_{1/2}  = sqrt(pi/(2 x)) e^-x
   */
  {
    double half = 0.5;
    for (x = 0.05; x <= 200.0; x *= 1.13) {
      double root = sqrt(2.0 / (M_PI * x));
      /* series regime below the crossover, asymptotic above it */
      double jtol = (x <= 12.0) ? 5e-12 : (x <= 18.0 ? 2e-9 : 1e-7);
      double ytol = (x <= 12.0) ? 1e-9 : (x <= 18.0 ? 1e-8 : 1e-7);
      check_pair("j_half", half, x, te_bessel_j(half, x), root * sin(x), jtol);
      check_pair("y_half", half, x, te_bessel_y(half, x), -root * cos(x), ytol);
      check_pair("i_half", half, x, te_bessel_i(half, x),
                 root * (exp(x) - exp(-x)) * 0.5, 1e-10);
      check_pair("k_half", half, x, te_bessel_k(half, x),
                 sqrt(M_PI / (2.0 * x)) * exp(-x), 1e-6);
    }
  }

  /* Integer I_n / K_n against captured scipy values (libm has no I/K). */
  {
    static const struct { int n; double x, i, k; } reference[] = {
        {0, 0.5, 1.0634833707413236, 0.92441907122766565},
        {0, 1.0, 1.2660658777520084, 0.42102443824070834},
        {0, 5.0, 27.239871823604453, 0.0036910983340425934},
        {0, 20.0, 43558282.559553534, 5.7412378153365227e-10},
        {0, 40.0, 14894774793419894.0, 8.3928611000995672e-19},
        {1, 0.5, 0.25789430539089636, 1.6564411200033007},
        {1, 1.0, 0.56515910399248503, 0.60190723019723458},
        {1, 5.0, 24.335642142450531, 0.0040446134454521629},
        {1, 20.0, 42454973.385127768, 5.8830579695570363e-10},
        {2, 1.0, 0.13574766976703831, 1.6248388986351774},
        {3, 2.0, 0.21273995923985264, 0.64738539094863423},
        {5, 10.0, 777.18828640325989, 5.7541849985312281e-05},
    };
    unsigned long i;
    for (i = 0; i < sizeof(reference) / sizeof(reference[0]); i++) {
      check_pair("bessel_i_ref", reference[i].n, reference[i].x,
                 te_bessel_i(reference[i].n, reference[i].x), reference[i].i, 1e-12);
      /* K: exact-form series below the crossover (~1e-8) and the asymptotic
       * above it (~1e-9); higher orders lose a few digits to cancellation. */
      check_pair("bessel_k_ref", reference[i].n, reference[i].x,
                 te_bessel_k(reference[i].n, reference[i].x), reference[i].k, 1e-5);
    }
  }

  printf("%d checks, %d failures\n", checks, failures);
  return failures > 0 ? 1 : 0;
}
