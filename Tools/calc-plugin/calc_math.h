/* TypstEdit calculator plugin — numeric core.
 *
 * Freestanding C99: no libc, no math.h. Everything the plugin needs is
 * implemented here so the module can be compiled to wasm32 with
 * `clang --target=wasm32 -nostdlib` and linked with `wasm-ld`.
 *
 * The elementary functions (exp, log, sin, cos, pow) follow the classic
 * fdlibm algorithms (Sun's freely licensed libm); the special functions
 * (gamma, Bessel J/Y/I/K) use the Lanczos approximation, power series and
 * Hankel asymptotics. Accuracy is verified against the platform libm/scipy
 * by `Tools/calc-plugin/tests/test_numerics.c`.
 */
#ifndef TYPSTEDIT_CALC_MATH_H
#define TYPSTEDIT_CALC_MATH_H

double te_exp(double x);
double te_log(double x);
double te_pow(double base, double exponent);
double te_sin(double x);
double te_cos(double x);

double te_gamma(double z);
double te_lgamma(double z);

double te_bessel_j(double order, double x);
double te_bessel_y(double order, double x);
double te_bessel_i(double order, double x);
double te_bessel_k(double order, double x);

/* ---- generic function library (see calc_dispatch.c for the name registry) ---- */

double te_trunc(double x);
double te_floor(double x);
double te_ceil(double x);
double te_round(double x);
double te_fmod(double a, double b);

double te_atan(double x);
double te_atan2(double y, double x);
double te_asin(double x);
double te_acos(double x);
double te_tan(double x);
double te_sinh(double x);
double te_cosh(double x);
double te_tanh(double x);
double te_asinh(double x);
double te_acosh(double x);
double te_atanh(double x);
double te_sinc(double x);
double te_cbrt(double x);
double te_hypot(double a, double b);

double te_digamma(double z);
double te_beta(double a, double b);
double te_erf(double x);
double te_erfc(double x);
double te_erfinv(double p);
double te_gammainc_p(double a, double x);
double te_gammainc_q(double a, double x);
double te_betainc(double a, double b, double x);
double te_zeta(double s);
double te_lambert_w(double x);
double te_lambert_wm1(double x);
double te_ei(double x);
double te_e1(double x);
double te_li(double x);
double te_si(double x);
double te_ci(double x);
double te_airy_ai(double x);
double te_airy_bi(double x);
double te_sph_bessel_j(double n, double x);
double te_sph_bessel_y(double n, double x);

double te_legendre_p(double n, double x);
double te_chebyshev_t(double n, double x);
double te_chebyshev_u(double n, double x);
double te_hermite_h(double n, double x);
double te_laguerre_l(double n, double x);

double te_ellip_k(double m);
double te_ellip_e(double m);
double te_jacobi_sn(double u, double m);
double te_jacobi_cn(double u, double m);
double te_jacobi_dn(double u, double m);

double te_factorial(double n);
double te_binom(double n, double k);
double te_npr(double n, double r);
double te_gcd(double a, double b);
double te_lcm(double a, double b);

#endif /* TYPSTEDIT_CALC_MATH_H */
