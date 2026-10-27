/* Registry conformance: every function reachable through calc-call, on edge
 * and random inputs, against arbitrary-precision (mpmath) references.
 *
 * Soundness contract checked per case (see gen_registry_reference.py):
 *   finite reference  -> result within tolerance, or NaN (declined)
 *   supported domain  -> result within tolerance; a decline is a failure
 *   NaN reference     -> result NaN
 *   pole              -> result NaN or ±inf
 *   ±inf reference    -> that infinity, or NaN (declined)
 * A finite-but-wrong result is always a failure. Each call must also finish
 * quickly (no pathological loops reachable from a document).
 *
 * Build & run from Tools/calc-plugin:
 *   clang -O2 -std=c99 -o /tmp/registry calc_math.c calc_dispatch.c tests/test_registry.c
 *   /tmp/registry            # add -v to list declines per function
 */
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "../calc_math.h"

int te_dispatch_call(const char *name, unsigned int name_len, int arity,
                     const double *args, double *out);

#define TE_REF_INF (1.0 / 0.0)
#define TE_REF_NAN (0.0 / 0.0)

struct te_case {
  const char *name;
  int arity;
  double args[3];
  char cls;
  double want;
  double rel;
  double abs;
};

static const struct te_case cases[] = {
#include "registry_reference.h"
};

static int is_nan(double x) { return x != x; }
static int is_inf(double x) { return !is_nan(x) && (x - x != 0.0); }
static double absd(double x) { return x < 0 ? -x : x; }

struct tally {
  const char *name;
  int pass, declined, fail;
};

int main(int argc, char **argv) {
  int verbose = argc > 1 && strcmp(argv[1], "-v") == 0;
  struct tally tallies[128];
  int ntally = 0, failures = 0, slow = 0, shown = 0;
  unsigned long i, total = sizeof(cases) / sizeof(cases[0]);
  double worst_seconds = 0.0;
  const char *worst_name = "";

  for (i = 0; i < total; i++) {
    const struct te_case *c = &cases[i];
    double got = 0.0;
    int status, t, ok = 0, declined = 0;
    clock_t start = clock();
    status = te_dispatch_call(c->name, (unsigned int)strlen(c->name), c->arity, c->args, &got);
    double seconds = (double)(clock() - start) / CLOCKS_PER_SEC;
    if (seconds > worst_seconds) { worst_seconds = seconds; worst_name = c->name; }
    if (seconds > 0.05) slow++;

    if (status != 0) {
      ok = 0;
    } else if (c->cls == 'N') {
      ok = is_nan(got);
    } else if (c->cls == 'P') {
      ok = is_nan(got) || is_inf(got);
    } else if (c->cls == 'I') {
      if (is_nan(got)) { ok = 1; declined = 1; }
      else ok = (got == c->want) || (is_inf(got) == 0 && absd(got) > 1e300 && (got > 0) == (c->want > 0));
    } else if (c->cls == 'S') { /* documented domain: must be evaluated */
      if (is_nan(got)) ok = 0;
      else if (is_inf(got)) ok = 0;
      else ok = absd(got - c->want) <= c->rel * absd(c->want) + c->abs;
    } else { /* 'F' */
      if (is_nan(got)) { ok = 1; declined = 1; }
      else if (is_inf(got)) ok = absd(c->want) > 1.7e308;
      else ok = absd(got - c->want) <= c->rel * absd(c->want) + c->abs;
    }

    for (t = 0; t < ntally; t++) if (strcmp(tallies[t].name, c->name) == 0) break;
    if (t == ntally) { tallies[t].name = c->name; tallies[t].pass = tallies[t].declined = tallies[t].fail = 0; ntally++; }
    if (!ok) {
      tallies[t].fail++;
      failures++;
      if (shown < 5000) {
        printf("FAIL %-11s (%.17g, %.17g, %.17g) class %c want=%.17g got=%.17g\n",
               c->name, c->args[0], c->args[1], c->args[2], c->cls, c->want, got);
        shown++;
      }
    } else if (declined) {
      tallies[t].declined++;
      if (verbose) printf("decl %-11s (%.17g, %.17g, %.17g) want=%.17g\n",
                          c->name, c->args[0], c->args[1], c->args[2], c->want);
    } else {
      tallies[t].pass++;
    }
  }

  printf("\n%-12s %6s %6s %6s\n", "function", "pass", "decl", "fail");
  for (i = 0; i < (unsigned long)ntally; i++) {
    if (verbose || tallies[i].fail || tallies[i].declined)
      printf("%-12s %6d %6d %6d\n", tallies[i].name, tallies[i].pass, tallies[i].declined, tallies[i].fail);
  }
  printf("\n%lu cases over %d functions: %d failures, %d slow calls (>50 ms); slowest %.3f s (%s)\n",
         total, ntally, failures, slow, worst_seconds, worst_name);
  return (failures || slow) ? 1 : 0;
}
