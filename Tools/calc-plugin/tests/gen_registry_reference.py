#!/usr/bin/env python3
"""Generates tests/registry_reference.h: arbitrary-precision reference values
for EVERY function in the plugin registry (calc_dispatch.c).

Each case records the inputs, the expected outcome class and a tolerance
derived from that function's documented error model:

  F  finite value      -> result must be within tolerance, or NaN (declined)
  N  undefined/complex -> result must be NaN
  P  pole              -> result must be NaN or ±inf
  I  ±infinity         -> result must be that infinity, or NaN (declined)

The point of the classes: a function may *decline* (NaN) where it cannot
guarantee accuracy, but it may never return a finite value that is wrong.

Run from Tools/calc-plugin:  python3 tests/gen_registry_reference.py
Requires mpmath (pip install mpmath). The generated header is checked in, so
the C test itself needs no Python.
"""
import math
import random
import re
import signal
import sys

import mpmath as mp

mp.mp.dps = 40
random.seed(20261027)
INF = float("inf")
NAN = float("nan")

EDGES = [0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 2.0, -2.0, 3.0, 10.0, -10.0, 100.0,
         1e-300, -1e-300, 1e-10, -1e-10, 1e10, -1e10, 1e300, -1e300,
         INF, -INF, NAN, 0.1, 7.25, 1e5, -1e5]


def log_uniform(lo, hi, signed=True):
    v = math.exp(random.uniform(math.log(lo), math.log(hi)))
    return -v if signed and random.random() < 0.5 else v


def randoms(n, lo=1e-6, hi=1e6, signed=True):
    out = [log_uniform(lo, hi, signed) for _ in range(n // 2)]
    out += [random.uniform(-10, 10) if signed else random.uniform(0, 10) for _ in range(n - n // 2)]
    return out


class Timeout(Exception):
    pass


def _alarm(signum, frame):
    raise Timeout()


signal.signal(signal.SIGALRM, _alarm)


def classify(fn, args):
    """Evaluates the reference; returns (class, value) or None (skip)."""
    if not getattr(fn, "handles_nan", False) and any(isinstance(a, float) and math.isnan(a) for a in args):
        return ("N", NAN)
    signal.alarm(3)
    try:
        v = fn(*args)
    except Timeout:
        return None
    except ZeroDivisionError:
        return ("P", NAN)
    except (ValueError, OverflowError) as e:
        text = str(e).lower()
        if "pole" in text or "gamma" in text and "pole" in text:
            return ("P", NAN)
        return None if "overflow" not in text else ("I", INF)
    finally:
        signal.alarm(0)
    if v is None:
        return ("N", NAN)
    if isinstance(v, str):
        return (v, NAN)  # explicit class from a wrapper
    if isinstance(v, (mp.mpc, complex)):
        if abs(mp.im(v)) > mp.mpf(10) ** (-30) * max(1, abs(mp.re(v))):
            return ("N", NAN)
        v = mp.re(v)
    if isinstance(v, mp.mpf) and mp.isnan(v):
        return ("N", NAN)
    if isinstance(v, mp.mpf) and mp.isinf(v):
        return ("I", float(v))
    f = float(v)
    if math.isinf(f):
        return ("I", f)
    return ("F", f)


def m(x):
    return mp.mpf(x) if not (isinstance(x, float) and math.isinf(x)) else mp.inf if x > 0 else -mp.inf


# ---------------------------------------------------------------------------
# Reference semantics, one entry per registry name (real-valued results).
# ---------------------------------------------------------------------------

def real_log(x):
    if x < 0:
        return None
    if x == 0:
        return -mp.inf
    return mp.log(m(x))


def c99(f, exact=None):
    """libm-semantics reference via Python's math, which implements the C99
    special values (pow(NaN, 0) = 1, hypot(inf, NaN) = inf, ...). On overflow
    the sign of the infinity comes from the exact mpmath function."""
    def wrap(*a):
        try:
            return mp.mpf(f(*a))
        except ValueError:
            return None
        except OverflowError:
            v = exact(*[m(x) for x in a]) if exact else mp.mpf(1)
            return mp.inf if v > 0 else -mp.inf
    wrap.handles_nan = True
    return wrap


def ref_round(x):
    if math.isinf(x):
        return mp.mpf(x)
    v = mp.mpf(x)
    return mp.floor(v + mp.mpf(0.5)) if v >= 0 else -mp.floor(-v + mp.mpf(0.5))


def ref_trunc(x):
    if math.isinf(x):
        return mp.mpf(x)
    v = mp.mpf(x)
    return mp.floor(v) if v >= 0 else -mp.floor(-v)


def ref_roundto(x, d):
    if d != int(d) or abs(d) > 22:
        return None
    if math.isinf(x):
        return mp.mpf(x)
    scale = mp.mpf(10) ** int(d)
    return ref_round_exact(mp.mpf(x) * scale) / scale


def ref_round_exact(v):
    return mp.floor(v + mp.mpf(0.5)) if v >= 0 else -mp.floor(-v + mp.mpf(0.5))


def ref_gamma(x):
    if x <= 0 and x == int(x):
        return "P"
    return mp.gamma(m(x))


def ref_lgamma(x):
    if x <= 0 and x == int(x):
        return "P"
    if math.isinf(x):
        return mp.inf
    return mp.log(abs(mp.gamma(m(x)))) if abs(x) < 1e5 else mp.re(mp.loggamma(m(x)))


def ref_digamma(x):
    if x <= 0 and x == int(x):
        return "P"
    if x == INF:
        return mp.inf
    if x == -INF:
        return None
    return mp.digamma(m(x))


def ref_beta(a, b):
    if a <= 0 or b <= 0 or math.isinf(a) or math.isinf(b):
        return None  # outside the documented domain: must decline
    return mp.beta(m(a), m(b))


def ref_factorial(n):
    if n < 0 and n == int(n):
        return "P"
    if n == INF:
        return mp.inf
    if n == -INF:
        return None
    return mp.gamma(m(n) + 1)


def ref_binom(n, k):
    if math.isinf(n) or k != int(k) or math.isinf(k):
        return None
    if k < 0:
        return mp.mpf(0)
    return mp.binomial(m(n), int(k))


def ref_npr(n, r):
    if math.isinf(n) or r != int(r) or r < 0 or math.isinf(r):
        return None
    return mp.rf(m(n) - int(r) + 1, int(r))


def ref_gcd(a, b):
    if a != int(a) or b != int(b) or math.isinf(a) or math.isinf(b):
        return None
    if abs(a) > 2 ** 53 or abs(b) > 2 ** 53:
        return None
    return mp.mpf(math.gcd(int(a), int(b)))


def ref_lcm(a, b):
    g = ref_gcd(a, b)
    if g is None:
        return None
    if g == 0:
        return mp.mpf(0)
    return mp.mpf(abs(int(a)) // int(g) * abs(int(b)))


def ref_fmod(a, b):
    try:
        return mp.mpf(math.fmod(a, b))
    except ValueError:
        return None


def ref_gammainc(a, x, upper=False):
    if a <= 0 or x < 0 or math.isinf(a):
        return None
    if math.isinf(x):
        return mp.mpf(0 if upper else 1)
    return mp.gammainc(m(a), m(x), mp.inf, regularized=True) if upper else \
        mp.gammainc(m(a), 0, m(x), regularized=True)


def ref_betainc(a, b, x):
    if a <= 0 or b <= 0 or x < 0 or x > 1 or math.isinf(a) or math.isinf(b):
        return None
    return mp.betainc(m(a), m(b), 0, m(x), regularized=True)


def ref_ei(x):
    if x == 0:
        return -mp.inf
    if x == INF:
        return mp.inf
    if x == -INF:
        return mp.mpf(0)
    return mp.ei(m(x))


def ref_e1(x):
    if x < 0:
        return None
    if x == 0:
        return mp.inf
    if x == INF:
        return mp.mpf(0)
    return mp.e1(m(x))


def ref_li(x):
    if x < 0:
        return None
    if x == 0:
        return mp.mpf(0)
    if x == 1:
        return -mp.inf
    if x == INF:
        return mp.inf
    return mp.li(m(x))


def ref_si(x):
    if math.isinf(x):
        return mp.pi / 2 if x > 0 else -mp.pi / 2
    return mp.si(m(x))


def ref_ci(x):
    if x < 0:
        return None
    if x == 0:
        return -mp.inf
    if x == INF:
        return mp.mpf(0)
    return mp.ci(m(x))


def ref_zeta(s):
    if s == 1:
        return "P"
    if s == INF:
        return mp.mpf(1)
    if s == -INF:
        return None
    return mp.zeta(m(s))


def ref_lambertw(x, branch=0):
    if math.isinf(x):
        return mp.inf if (x > 0 and branch == 0) else None
    if x == -1 / math.e:
        return mp.mpf(-1)  # the double nearest -1/e *is* the branch point
    if x < -1 / math.e:
        return None
    if branch == -1 and x >= 0:
        return None
    return mp.lambertw(m(x), branch)


def ref_airy(x, which):
    if math.isinf(x):
        if which == "ai":
            return mp.mpf(0)
        return mp.inf if x > 0 else mp.mpf(0)
    return mp.airyai(m(x)) if which == "ai" else mp.airybi(m(x))


def ref_besselj(n, x):
    if math.isinf(n):
        return None
    if math.isinf(x):
        return mp.mpf(0) if (x > 0 or n == int(n)) else None
    if x < 0 and n != int(n):
        return None
    if x == 0:
        if n == 0:
            return mp.mpf(1)
        return mp.mpf(0) if (n > 0 or n == int(n)) else None
    return mp.besselj(m(n), m(x))


def ref_bessely(n, x):
    if math.isinf(n) or x < 0:
        return None
    if x == 0:
        return -mp.inf if n >= 0 else None
    if math.isinf(x):
        return mp.mpf(0)
    return mp.bessely(m(n), m(x))


def ref_besseli(n, x):
    if math.isinf(n):
        return None
    if x < 0 and n != int(n):
        return None
    if math.isinf(x):
        if x > 0:
            return mp.inf
        return (-mp.inf if int(n) % 2 else mp.inf) if n == int(n) else None  # I_n(-x) = (-1)^n I_n(x)
    if x == 0:
        if n == 0:
            return mp.mpf(1)
        return mp.mpf(0) if (n > 0 or n == int(n)) else None
    return mp.besseli(m(n), m(x))


def ref_besselk(n, x):
    if math.isinf(n) or x < 0:
        return None
    if x == 0:
        return mp.inf
    if math.isinf(x):
        return mp.mpf(0)
    return mp.besselk(m(n), m(x))


def ref_sph(n, x, kind):
    if math.isinf(n):
        return None
    if math.isinf(x):
        return mp.mpf(0)
    if x == 0:
        if kind == "j":
            return mp.mpf(1) if n == 0 else (mp.mpf(0) if n > 0 else None)
        return -mp.inf if n >= 0 else None
    if x < 0:
        if n != int(n):
            return None
        v = ref_sph(n, -x, kind)
        if v is None or isinstance(v, str):
            return v
        odd = int(n) % 2 == 1
        if kind == "j":
            return -v if odd else v
        return v if odd else -v
    root = mp.sqrt(mp.pi / (2 * m(x)))
    return root * (mp.besselj(m(n) + 0.5, m(x)) if kind == "j" else mp.bessely(m(n) + 0.5, m(x)))


def ref_poly(kind):
    def f(n, x):
        if n != int(n) or n < 0 or n > 200:
            return None
        if math.isinf(x):
            if n == 0:
                return mp.mpf(1)
            # leading coefficient is positive except Laguerre's (-1)^n / n!
            sign = 1 if (x > 0 or int(n) % 2 == 0) else -1
            if kind == "laguerre" and int(n) % 2 == 1:
                sign = -sign
            return mp.inf * sign
        n = int(n)
        if kind == "legendre":
            return mp.legendre(n, m(x))
        if kind == "chebyt":
            return mp.chebyt(n, m(x))
        if kind == "chebyu":
            return mp.chebyu(n, m(x))
        if kind == "hermite":
            return mp.hermite(n, m(x))
        return mp.laguerre(n, 0, m(x))
    return f


def ref_ellipk(mm):
    if mm > 1:
        return None
    if mm == 1:
        return mp.inf
    if mm == -INF:
        return mp.mpf(0)
    return mp.ellipk(m(mm))


def ref_ellipe(mm):
    if mm > 1 or math.isinf(mm):
        return None
    return mp.ellipe(m(mm))


def ref_jacobi(kind):
    def f(u, mm):
        if math.isinf(u) or mm < 0 or mm > 1:
            return None
        return mp.ellipfun(kind, m(u), m=m(mm))
    return f


def ref_sinc(x):
    if math.isinf(x):
        return mp.mpf(0)
    if x == 0:
        return mp.mpf(1)
    return mp.sin(m(x)) / m(x)


def ref_frac(x):
    if math.isinf(x):
        return None
    return m(x) - ref_trunc(x)


def ref_sign(x):
    return mp.mpf(0 if x == 0 else (1 if x > 0 else -1))


def ref_minmax(f):
    def g(a, b):
        return mp.mpf(f(a, b))
    return g


def ref_logb(x, b):
    lx, lb = real_log(x), real_log(b)
    if lx is None or lb is None:
        return None
    if lb == 0:
        return "P"
    if mp.isinf(lx) and mp.isinf(lb):
        return None
    return lx / lb


def ref_atanh(x):
    if abs(x) > 1:
        return None
    if abs(x) == 1:
        return mp.inf if x > 0 else -mp.inf
    return mp.atanh(m(x))


REF = {
    "exp": c99(math.exp, mp.exp), "ln": real_log, "log": real_log,
    "log10": lambda x: None if x < 0 else (-mp.inf if x == 0 else mp.log10(m(x))),
    "log2": lambda x: None if x < 0 else (-mp.inf if x == 0 else mp.log(m(x), 2)),
    "logb": ref_logb, "sqrt": c99(math.sqrt), "cbrt": lambda x: mp.cbrt(m(x)) if x >= 0 else -mp.cbrt(-m(x)),
    # C99: pow(±0, y < 0) is a pole (±inf); Python raises a domain error instead.
    "pow": None, "hypot": c99(math.hypot, mp.hypot), "hypot": c99(math.hypot, mp.hypot),
    "sin": c99(math.sin), "cos": c99(math.cos), "tan": c99(math.tan),
    "asin": c99(math.asin), "arcsin": c99(math.asin), "acos": c99(math.acos), "arccos": c99(math.acos),
    "atan": c99(math.atan), "arctan": c99(math.atan), "atan2": c99(math.atan2),
    "sinh": c99(math.sinh, mp.sinh), "cosh": c99(math.cosh, mp.cosh), "tanh": c99(math.tanh),
    "asinh": c99(math.asinh), "acosh": c99(math.acosh), "atanh": ref_atanh,
    "sinc": ref_sinc, "deg": c99(math.degrees, mp.degrees), "rad": c99(math.radians, mp.radians),
    "abs": c99(abs), "floor": lambda x: mp.mpf(x) if math.isinf(x) else mp.floor(m(x)),
    "ceil": lambda x: mp.mpf(x) if math.isinf(x) else mp.ceil(m(x)),
    "trunc": ref_trunc, "frac": ref_frac, "round": ref_round, "roundto": ref_roundto,
    "sign": ref_sign, "min": ref_minmax(min), "max": ref_minmax(max), "mod": ref_fmod,
    "gcd": ref_gcd, "lcm": ref_lcm,
    "gamma": ref_gamma, "lgamma": ref_lgamma, "digamma": ref_digamma, "beta": ref_beta,
    "factorial": ref_factorial, "fact": ref_factorial,
    "binom": ref_binom, "comb": ref_binom, "npr": ref_npr, "perm": ref_npr,
    "erf": lambda x: mp.erf(m(x)), "erfc": lambda x: mp.erfc(m(x)),
    "erfinv": lambda p: None if abs(p) > 1 else (mp.inf if p == 1 else (-mp.inf if p == -1 else mp.erfinv(m(p)))),
    "gammainc": lambda a, x: ref_gammainc(a, x, False), "gammaincc": lambda a, x: ref_gammainc(a, x, True),
    "betainc": ref_betainc, "ei": ref_ei, "e1": ref_e1, "li": ref_li, "si": ref_si, "ci": ref_ci,
    "zeta": ref_zeta, "lambertw": lambda x: ref_lambertw(x, 0), "lambertwm1": lambda x: ref_lambertw(x, -1),
    "airyai": lambda x: ref_airy(x, "ai"), "airybi": lambda x: ref_airy(x, "bi"),
    "besselj": ref_besselj, "bessely": ref_bessely, "besseli": ref_besseli, "besselk": ref_besselk,
    "sphbesselj": lambda n, x: ref_sph(n, x, "j"), "sphbessely": lambda n, x: ref_sph(n, x, "y"),
    "legendre": ref_poly("legendre"), "chebyt": ref_poly("chebyt"), "chebyu": ref_poly("chebyu"),
    "hermite": ref_poly("hermite"), "laguerre": ref_poly("laguerre"),
    "ellipk": ref_ellipk, "ellipe": ref_ellipe,
    "jacobisn": ref_jacobi("sn"), "jacobicn": ref_jacobi("cn"), "jacobidn": ref_jacobi("dn"),
}

def _ref_pow(a, b, _f=c99(math.pow, mp.power)):
    if a == 0 and b < 0:
        return "P"
    return _f(a, b)


_ref_pow.handles_nan = True
REF["pow"] = _ref_pow

# ---------------------------------------------------------------------------
# Inputs per function
# ---------------------------------------------------------------------------

ORDERS = [0.0, 1.0, 2.0, 3.0, 5.0, 10.0, 25.0, 60.0, 0.5, 1.0 / 3.0, -1.0 / 3.0, 2.5, 7.3, -1.0, -2.0, -2.5,
          1.00000001, 2.0 + 1e-10, INF, NAN]
BESSEL_X = [0.0, 1e-300, 1e-5, 0.3, 1.0, 1.9, 2.0, 2.1, 5.0, 6.0, 7.5, 11.0, 11.5, 12.0, 17.9, 18.0, 18.1,
            24.0, 30.0, 59.0, 100.0, 333.0, 1e4, 1e9, 1e11, -1.0, -7.5, -30.0, INF, -INF, NAN] + \
    [log_uniform(1e-3, 3e3, False) for _ in range(16)]


def inputs_for(name, arity):
    if name.startswith("bessel") or name.startswith("sphbessel"):
        return [(n, x) for n in ORDERS for x in BESSEL_X]
    if name in ("legendre", "chebyt", "chebyu", "hermite", "laguerre"):
        ns = [0.0, 1.0, 2.0, 3.0, 5.0, 10.0, 30.0, 100.0, 200.0, 201.0, 2.5, -1.0, NAN]
        xs = [0.0, 0.3, -0.7, 1.0, -1.0, 0.999, 1.5, -2.5, 10.0, 1e10, INF, NAN] + \
            [random.uniform(-1.2, 1.2) for _ in range(6)]
        return [(n, x) for n in ns for x in xs]
    if name in ("jacobisn", "jacobicn", "jacobidn"):
        us = [0.0, 0.5, -1.3, 3.0, 20.0, -50.0, 1e4, 1e12, INF, NAN] + [random.uniform(-30, 30) for _ in range(6)]
        ms = [0.0, 1e-12, 0.1, 0.5, 0.9, 0.999999, 1.0 - 1e-15, 1.0, -0.5, 1.5, NAN]
        return [(u, q) for u in us for q in ms]
    if name in ("gammainc", "gammaincc"):
        as_ = [1e-3, 0.1, 0.5, 1.0, 2.0, 5.0, 20.0, 100.0, 1e3, 1e5, -1.0, 0.0, INF, NAN]
        xs = [0.0, 1e-8, 0.1, 0.5, 1.0, 3.0, 10.0, 99.0, 101.0, 1e3, 1e5, -1.0, INF, NAN]
        return [(a, x) for a in as_ for x in xs]
    if name == "betainc":
        ab = [0.1, 0.5, 1.0, 2.0, 5.0, 30.0, 300.0, -1.0, NAN]
        xs = [0.0, 1e-6, 0.1, 0.3, 0.5, 0.7, 0.99, 1.0, 1.5, NAN]
        return [(a, b, x) for a in ab for b in ab[:6] for x in xs]
    if name in ("binom", "comb", "npr", "perm"):
        ns = [0.0, 1.0, 5.0, 10.0, 50.0, 170.0, 1000.0, 1e6, 1e15, 0.5, 2.5, -2.0, -3.5, INF, NAN]
        ks = [0.0, 1.0, 2.0, 3.0, 7.0, 25.0, 100.0, 500.0, 2001.0, 1e5, -1.0, 1.5, NAN]
        return [(n, k) for n in ns for k in ks]
    if name in ("gcd", "lcm", "mod"):
        vs = [0.0, 1.0, -1.0, 6.0, -15.0, 35.0, 2.0 ** 40, 2.0 ** 53, 2.0 ** 60, 1e300, 2.5, -7.25, INF, NAN, -0.0]
        return [(a, b) for a in vs for b in vs]
    if name == "roundto":
        xs = [0.0, 1.2345678901234, -9.87654321, 123456.789012, 1e-8 * 1.2345678, 2.5, -2.5, INF, NAN] + \
            [random.uniform(-1000, 1000) for _ in range(8)]
        ds = [0.0, 1.0, 2.0, 5.0, 10.0, -1.0, -3.0, 22.0, 23.0, 1.5, NAN]
        return [(x, d) for x in xs for d in ds]
    if name in ("beta",):
        vs = [1e-3, 0.5, 1.0, 2.0, 3.5, 10.0, 80.0, 90.0, 200.0, 1e6, 0.0, -1.0, -0.5, INF, NAN]
        return [(a, b) for a in vs for b in vs]
    if name == "zeta":
        return [(s,) for s in EDGES + [1.0 + 1e-9, 1.1, 0.75, -1.0, -2.0, -3.0, -4.5, -20.0, -21.0, -101.0, -200.0, -260.0, 50.0]
                + randoms(16, 1e-3, 300)]
    if name in ("lambertw", "lambertwm1"):
        e = -1 / math.e
        return [(x,) for x in EDGES + [e, e + 1e-12, e + 1e-6, -0.2, -0.36, -0.01, -1e-200, 50.0, 1e100]
                + randoms(12, 1e-6, 1e6)]
    if name in ("airyai", "airybi"):
        return [(x,) for x in EDGES + [0.99, 1.0, 1.01, -0.99, -1.01, 5.24, 5.25, -5.24, -5.25, 8.0, -8.0, 20.0, -20.0,
                                        100.0, -100.0, 150.0, -1e4, -1e7] + randoms(16, 1e-3, 200)]
    if name in ("ellipk", "ellipe"):
        return [(q,) for q in EDGES + [1.0 - 1e-15, 0.9999, -1e6, -5.0] + [random.uniform(-3, 1) for _ in range(12)]]
    if name in ("erfinv",):
        return [(p,) for p in EDGES + [0.999, -0.999, 1.0 - 2 ** -53, -(1.0 - 2 ** -53), 0.9999999999, 1e-17]
                + [random.uniform(-1, 1) for _ in range(16)]]
    if name in ("gamma", "lgamma", "digamma", "factorial", "fact"):
        return [(x,) for x in EDGES + [-3.0, -0.0001, -2.5, -50.5, -170.5, -171.5, 170.0, 171.0, 172.0, 1e15, -1e15,
                                        1.4616321449683623, -2.4570247, 4.0 - 1e-12]
                + randoms(20, 1e-5, 500)]
    if arity == 1:
        return [(x,) for x in EDGES + randoms(30)]
    if arity == 2:
        vs = EDGES[:16] + [INF, -INF, NAN] + randoms(6)
        return [(a, b) for a in vs for b in vs]
    raise SystemExit("no inputs for " + name)


# ---------------------------------------------------------------------------
# Tolerances: the documented error model, evaluated per case.
# ---------------------------------------------------------------------------

def tolerance(name, args, want):
    """Returns (relative, absolute) error allowed for this case."""
    a0 = args[0]
    x = args[-1]
    trig_abs = 1e-16 + 2e-21 * abs(a0) if not math.isinf(a0) else 0.0
    exact = {"floor", "ceil", "trunc", "frac", "round", "abs", "sign", "min", "max", "mod", "gcd"}
    if name in exact:
        return (0.0, 0.0)
    if name in ("sin", "cos"):
        return (1e-14, trig_abs)
    if name == "tan":
        t = abs(want) if want else 1e-300
        return (1e-14 + trig_abs * (t + 1.0 / t), 0.0)
    if name == "sinc":
        return (1e-14, trig_abs / max(1.0, abs(a0)))
    if name == "pow":
        b = args[1]
        try:
            mag = abs(b * math.log(abs(args[0]))) if args[0] not in (0.0,) else 0.0
        except (ValueError, OverflowError):
            mag = 0.0
        return (4e-16 * (mag + 4.0), 1e-300)
    if name in ("exp",):
        return (1e-15, 0.0)
    if name in ("sinh", "cosh"):
        return (1e-14, 0.0)
    if name in ("ln", "log", "log10", "log2", "logb", "sqrt", "cbrt", "hypot", "atan", "arctan", "atan2",
                "asin", "arcsin", "acos", "arccos", "deg", "rad", "tanh", "asinh", "acosh", "atanh", "lcm"):
        return (4e-15, 1e-300)
    if name == "roundto":
        return (4e-16, 0.0)
    if name in ("gamma", "factorial", "fact"):
        z = a0 + (1.0 if name != "gamma" else 0.0)
        lg = abs(float(mp.re(mp.loggamma(m(z))))) if abs(z) < 1e300 else 0.0
        return (2e-14 + 1e-15 * lg + (1e-13 if z < 0.5 else 0.0), 1e-300)
    if name == "lgamma":
        return (1e-14, 1e-15)
    if name == "digamma":
        return (2e-13, 3e-14)  # absolute near the root at 1.4616 (recurrence sum)
    if name == "beta":
        return (1e-10, 1e-300)
    if name in ("binom", "comb", "npr", "perm"):
        return (1e-10 if args[1] > 2000 else 5e-13, 1e-300)
    if name in ("erf",):
        return (1e-14, 0.0)
    if name in ("erfc",):
        return (1e-13, 1e-300)
    if name == "erfinv":
        return (1e-13, 0.0)
    if name in ("gammainc", "gammaincc"):
        a = args[0]
        mag = abs(a * math.log(max(x, 1e-300))) + abs(x) + abs(math.lgamma(a)) if a > 0 and x > 0 and not math.isinf(x) else 0.0
        rel = 1e-13 + 2e-16 * mag
        # The complement is formed as 1 - (other): absolute accuracy ~1e-15
        # there (P for x >= a+1, Q for x < a+1).
        complement = (name == "gammaincc" and x < a + 1) or (name == "gammainc" and x >= a + 1)
        return (rel, 1e-15 if complement else 1e-300)
    if name == "betainc":
        return (1e-11, 1e-300)
    if name in ("ei", "e1"):
        return (1e-13, 1e-300)
    if name == "li":
        return (1e-13, 1e-14)
    if name in ("si", "ci"):
        return (1e-14, 1e-15 + 2e-21 * abs(a0))
    if name == "zeta":
        s = a0
        lg = abs(math.lgamma(1 - s)) if s < 0.5 and not math.isinf(s) else 0.0
        return (1e-13 + 1e-15 * (abs(s) * 3 + lg), 1e-300)
    if name in ("lambertw", "lambertwm1"):
        return (1e-14 + 2.2e-16 / max(abs(1.0 + want), 1e-300), 1e-300)
    if name in ("ellipk", "ellipe"):
        return (1e-13, 0.0)
    if name.startswith("jacobi"):
        # sin/cos-limited for large |u|; the Landen transform adds a few ulp
        return (1e-12, 1e-14 + 4e-16 * abs(a0))  # u's rounding grows with |u|
    if name in ("legendre", "chebyt", "chebyu", "hermite", "laguerre"):
        n = args[0]
        return (2e-14 * max(1.0, n), 1e-13 * max(1.0, n))
    if name.startswith("bessel") or name.startswith("sphbessel") or name.startswith("airy"):
        # Regime model (see calc_math.c): power series below x = 18, Hankel
        # expansion / recurrences above it (base accuracy ~3e-7 just past the
        # crossover), Steed's CF2 for K at x >= 2, Miller for J with n >= x.
        if name.startswith("airy"):
            xx = 2.0 / 3.0 * abs(x) ** 1.5 if abs(x) < 1e200 else INF
            env = 1.0 / (math.sqrt(math.pi) * max(abs(x), 1e-300) ** 0.25) if x < 0 else 0.0
        else:
            xx = abs(x)
            n = abs(args[0]) if not math.isnan(args[0]) else 0.0
            env = min(1.0, math.sqrt(2.0 / (math.pi * max(xx, 1e-300)))) if (n < xx and not name.endswith(("i", "k"))) else 0.0
        if name in ("besselk",) or (name == "airyai" and x > 0):
            rel = 1e-12
        elif name in ("besseli",) or (name == "airybi" and x > 0):
            rel = 1e-12
        elif xx <= 12.0:
            rel = 5e-10
        elif xx <= 18.0:
            rel = 3e-8
        else:
            rel = 6e-7
        return (rel, rel * env)
    if name == "e1":
        return (1e-13, 0.0)
    return (1e-14, 1e-300)


def lgamma_bound(*zs):
    if any(z <= 0 for z in zs):
        return float("inf")
    return sum(abs(math.lgamma(z)) for z in zs) * 4.4e-16


def supported(name, args, want):
    """True when the documented contract says this input must be evaluated
    (a decline there is a coverage failure, not an allowed refusal). These
    predicates mirror the routing in calc_math.c and serve as its spec."""
    if not all(math.isfinite(v) for v in args) or not math.isfinite(want) or abs(want) > 1e300:
        return False
    if 0 < abs(want) < 1e-290:
        return False  # results near underflow may lose to intermediate underflow
    a0, x = args[0], args[-1]
    if name in ("sin", "cos", "tan", "sinc", "si", "ci"):
        return abs(a0) <= 1e10
    if name.startswith("jacobi"):
        return abs(a0) <= 1e8 and 0.0 <= args[1] <= 1.0
    if name in ("airyai", "airybi"):
        return x >= 0 or (abs(x) < 1e7 and 2.0 / 3.0 * abs(x) ** 1.5 <= 1e10)
    if name in ("besselj", "sphbesselj"):
        n = a0 + (0.5 if name == "sphbesselj" else 0.0)
        xx = abs(x)
        if xx > 1e10 or abs(n) > 1e5:
            return False
        gap = n != int(n) and xx > 18 and n * n > xx and n >= xx and n < 0.25 * xx * xx
        return not gap
    if name in ("bessely", "sphbessely"):
        n = a0 + (0.5 if name == "sphbessely" else 0.0)
        band = n != int(n) and abs(n - round(n)) < 1e-7 and x <= 18
        return x <= 1e10 and abs(n) <= 1e5 and not band
    if name == "besselk":
        n = abs(a0)
        band = n != int(n) and 0 < abs(n - round(n)) < 1e-7 and x < 2
        return abs(n) <= 1e5 and not band
    if name == "besseli":
        return abs(a0) <= 1e5
    if name == "beta":
        a, b = args
        return a + b < 170 or lgamma_bound(a, b, a + b) <= 1e-10
    if name in ("binom", "comb"):
        nn, k = args
        if k <= 2000 or (nn == int(nn) and nn >= 0 and k > nn):
            return True  # direct product, or exactly 0
        return nn == int(nn) and nn >= 0 and lgamma_bound(nn + 1, k + 1, nn - k + 1) <= 1e-10
    if name in ("npr", "perm"):
        nn, r = args
        if r <= 2000:
            return True
        return nn == int(nn) and nn >= r and lgamma_bound(nn + 1, nn - r + 1) <= 1e-10
    if name in ("gammainc", "gammaincc"):
        return args[0] <= 1e4  # iteration count grows with a
    if name in ("legendre", "chebyt", "chebyu", "hermite", "laguerre"):
        return True
    return True


def chex(v):
    if math.isnan(v):
        return "TE_REF_NAN"
    if math.isinf(v):
        return "TE_REF_INF" if v > 0 else "-TE_REF_INF"
    return float(v).hex()


def main():
    registry = open("calc_dispatch.c").read()
    entries = re.findall(r'^\s*\{"([a-z0-9]+)", (\d)', registry, re.M)
    lines = []
    counts = {}
    for name, arity in entries:
        arity = int(arity)
        if name not in REF:
            raise SystemExit(f"registry function '{name}' has no reference: add it to REF")
        ref = REF[name]
        n = 0
        for args in inputs_for(name, arity):
            assert len(args) == arity, (name, args)
            outcome = classify(ref, args)
            if outcome is None:
                continue
            cls, value = outcome
            if cls == "F":
                if supported(name, args, value):
                    cls = "S"
                rel, ab = tolerance(name, args, value)
                # A non-finite tolerance would accept anything: clamp it, so
                # the case still demands at least the right sign/magnitude.
                rel = rel if math.isfinite(rel) else 1.0
                ab = ab if math.isfinite(ab) else 0.0
            else:
                rel, ab = (0.0, 0.0)
            padded = list(args) + [0.0] * (3 - arity)
            lines.append('  {"%s", %d, {%s}, \'%s\', %s, %.3g, %.3g},' % (
                name, arity, ", ".join(chex(a) for a in padded), cls, chex(value), rel, ab))
            n += 1
        counts[name] = n
    with open("tests/registry_reference.h", "w") as out:
        out.write("/* Generated by tests/gen_registry_reference.py — do not edit. */\n")
        out.write("/* %d cases over %d registry functions. */\n" % (len(lines), len(entries)))
        out.write("\n".join(lines) + "\n")
    print("wrote %d cases for %d functions" % (len(lines), len(entries)))
    missing = [k for k, v in counts.items() if v < 10]
    if missing:
        raise SystemExit("too few cases for: " + ", ".join(missing))


if __name__ == "__main__":
    main()
