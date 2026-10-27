// ==== TypstEdit calculator bridge ===========================================
//
// TypstEdit-exclusive Typst. Imported into the *shadow* copy of a document
// when the document uses calculator features; the saved file keeps its plain
// `#import`-free source, so it does not compile in standard Typst.
//
//   BesselJ/…        typed wrappers around the WASM numeric core
//   calc-call(name)  generic access to every function in that core
//   calc-fn(name)    the same, curried for plot()/loops
//   calc-param(v)    a document parameter (also fed to the CAS)
//   plot(…)          chart drawing (Typst layout, not math)
//
// The numeric core is TypstEditCalc.wasm, loaded from the same directory as
// this file. Adding a function needs no change here: it is registered by name
// in Tools/calc-plugin/calc_dispatch.c.

#let _calc = plugin("TypstEditCalc.wasm")

// Refuse a stale numeric core instead of failing later with a confusing
// "plugin does not contain function" error.
#let _calc-abi = float.from-bytes(_calc.abi_version(bytes((0,))), endian: "little")
#assert(
  _calc-abi >= 2,
  message: "TypstEditCalc.wasm is out of date (ABI " + str(_calc-abi) + "); rebuild with Tools/calc-plugin/build_calc_plugin.sh",
)

// Arguments are little-endian f64 both ways. Only real numbers are accepted:
// int, float and decimal. (Typst's float() would also take strings, bools
// and ratios; accepting those would silently turn "1.5" or 50% into numbers.)
// `float(…)` matters for ints: 8 bytes of i64 bits would read back as a
// denormal.
#let _calc-in(v) = {
  let t = type(v)
  assert(
    t == int or t == float or t == decimal,
    message: "calculator functions take numbers (int, float or decimal), got " + str(t),
  )
  float(v).to-bytes(endian: "little")
}
#let _calc-out(b) = float.from-bytes(b, endian: "little")

// ---- document parameters ---------------------------------------------------

/// Declares a document parameter. Typst sees the literal default; the same
/// value is stored in the CAS so `#calc("…")` and `#calc-table(…)` agree.
#let calc-param(default) = default

// ---- generic dispatch ------------------------------------------------------

/// Calls any function in the numeric core by name:
///   #calc-call("besselj", 0, 2.5)
///   #calc-call("erf", 0.3)
/// Names are case-insensitive. `#calc-functions()` lists what exists.
#let calc-call(name, ..args) = {
  assert(type(name) == str, message: "calc-call: the function name must be a string, got " + str(type(name)))
  assert(
    args.named().len() == 0,
    message: "calc-call: named arguments are not supported (got " + args.named().keys().join(", ") + ")",
  )
  let values = args.pos()
  // The plugin marshals *bytes*, so the name is encoded as UTF-8 bytes.
  let encoded = bytes(name)
  if values.len() == 1 {
    _calc-out(_calc.call1(encoded, _calc-in(values.at(0))))
  } else if values.len() == 2 {
    _calc-out(_calc.call2(encoded, _calc-in(values.at(0)), _calc-in(values.at(1))))
  } else if values.len() == 3 {
    _calc-out(_calc.call3(
      encoded,
      _calc-in(values.at(0)),
      _calc-in(values.at(1)),
      _calc-in(values.at(2)),
    ))
  } else {
    panic("calc-call takes 1 to 3 arguments, got " + str(values.len()))
  }
}

/// Curries a function for use where Typst wants a function of one variable:
///   #plot(calc-fn("besselj", 0), 0, 20)
///   #let f = calc-fn("erf")
#let calc-fn(name, ..pre) = {
  assert(pre.named().len() == 0, message: "calc-fn: named arguments are not supported")
  let fixed = pre.pos()
  x => calc-call(name, ..fixed, x)
}

/// The names the numeric core can evaluate, one per line.
/// Each line is "name/arity", e.g. "besselj/2".
#let calc-functions() = {
  let raw = _calc.functions(bytes((0,)))
  str(raw)
}

// ---- named wrappers --------------------------------------------------------
// These exist for readability in documents; they are thin aliases over
// calc-call and cover the functions documents use most.

#let BesselJ(order, x) = calc-call("besselj", order, x)
#let BesselY(order, x) = calc-call("bessely", order, x)
#let BesselI(order, x) = calc-call("besseli", order, x)
#let BesselK(order, x) = calc-call("besselk", order, x)
#let sphBesselJ(n, x) = calc-call("sphbesselj", n, x)
#let sphBesselY(n, x) = calc-call("sphbessely", n, x)

#let calc-gamma(z) = calc-call("gamma", z)
#let calc-lgamma(z) = calc-call("lgamma", z)
#let calc-digamma(z) = calc-call("digamma", z)
#let calc-beta(a, b) = calc-call("beta", a, b)
#let calc-erf(x) = calc-call("erf", x)
#let calc-erfc(x) = calc-call("erfc", x)
#let calc-zeta(s) = calc-call("zeta", s)
#let calc-ei(x) = calc-call("ei", x)
#let calc-si(x) = calc-call("si", x)
#let calc-ci(x) = calc-call("ci", x)
#let calc-airy-ai(x) = calc-call("airyai", x)
#let calc-airy-bi(x) = calc-call("airybi", x)
#let calc-lambert-w(x) = calc-call("lambertw", x)
#let calc-ellip-k(m) = calc-call("ellipk", m)
#let calc-ellip-e(m) = calc-call("ellipe", m)

// ---- plot ------------------------------------------------------------------

// Draws one or more curves on a labelled 2-D canvas.
//   #plot(x => BesselJ(0, x), 0, 10)
//   #plot(curves: ((fn: x => BesselJ(0, x), label: [J0]), (fn: calc-fn("erf"), label: [erf])), 0, 3)
//   #plot(points: #calc-table("a*x^2", x, 0, 3, 30), x-min: 0, x-max: 3)
#let _plot-palette = (
  rgb("#3b82f6"),
  rgb("#ef4444"),
  rgb("#22c55e"),
  rgb("#a855f7"),
  rgb("#f59e0b"),
)
#let _plot-finite(v) = v == v and calc.abs(v) != calc.inf

#let plot(
  ..args,
  points: none,
  curves: none,
  y-min: auto,
  y-max: auto,
  samples: 160,
  width: 340pt,
  height: 220pt,
  stroke: auto,
  grid: true,
  ticks: 6,
  title: none,
  legend: auto,
  border: true,
) = {
  // The first three arguments may be given positionally. When a `curves` or
  // `points` list supplies the data, positionals are (x-min, x-max);
  // otherwise they are (fn, x-min, x-max).
  let pos = args.pos()
  let data-first = curves != none or points != none
  let fn = if not data-first and pos.len() > 0 { pos.at(0) } else { args.at("fn", default: none) }
  let base = if data-first { 0 } else { 1 }
  let x-min = if pos.len() > base { pos.at(base) } else { args.at("x-min", default: 0) }
  let x-max = if pos.len() > base + 1 { pos.at(base + 1) } else { args.at("x-max", default: 10) }
  assert(pos.len() <= base + 2, message: "plot: too many positional arguments")
  for key in args.named().keys() {
    assert(key in ("fn", "x-min", "x-max"), message: "plot: unknown argument `" + key + "`")
  }
  assert(fn != none or curves != none or points != none, message: "plot: give a function, `curves:` or `points:`")
  assert(fn == none or type(fn) == function, message: "plot: the first argument must be a function, e.g. x => BesselJ(0, x)")
  assert(type(x-min) in (int, float) and type(x-max) in (int, float), message: "plot: x-min and x-max must be numbers")
  assert(x-min < x-max, message: "plot: x-min (" + str(x-min) + ") must be less than x-max (" + str(x-max) + ")")
  assert(type(samples) == int and samples >= 2 and samples <= 20000, message: "plot: samples must be an integer from 2 to 20000")
  assert(y-min == auto or y-max == auto or y-min < y-max, message: "plot: y-min must be less than y-max")

  let specs = ()
  if fn != none {
    specs.push((fn: fn, stroke: if stroke == auto { _plot-palette.at(0) } else { stroke }, label: none))
  }
  if curves != none {
    for (i, spec) in curves.enumerate() {
      let color = _plot-palette.at(calc.rem(i, _plot-palette.len()))
      if type(spec) == function {
        specs.push((fn: spec, stroke: color, label: none))
      } else {
        specs.push((
          fn: spec.at("fn"),
          stroke: if spec.at("stroke", default: none) != none { spec.at("stroke") } else { color },
          label: spec.at("label", default: none),
        ))
      }
    }
  }
  if points != none {
    specs.push((pts: points, stroke: if stroke == auto { _plot-palette.at(0) } else { stroke }, label: none))
  }

  let all-y = ()
  let sampled = ()
  for spec in specs {
    let pts = ()
    if "fn" in spec {
      for i in range(samples + 1) {
        let xv = x-min + (x-max - x-min) * i / samples
        let yv = (spec.at("fn"))(xv)
        if _plot-finite(yv) {
          pts.push((xv, yv))
          all-y.push(yv)
        }
      }
    } else {
      for pair in spec.at("pts") {
        if _plot-finite(float(pair.at(0))) and _plot-finite(float(pair.at(1))) {
          pts.push(pair)
          all-y.push(pair.at(1))
        }
      }
    }
    sampled.push((pts: pts, stroke: spec.at("stroke"), label: spec.at("label")))
  }

  let data-lo = if all-y.len() == 0 {
    0.0
  } else {
    let m = all-y.at(0)
    for v in all-y {
      if v < m { m = v }
    }
    m
  }
  let data-hi = if all-y.len() == 0 {
    1.0
  } else {
    let m = all-y.at(0)
    for v in all-y {
      if v > m { m = v }
    }
    m
  }
  let lo = if y-min == auto { data-lo } else { y-min }
  let hi = if y-max == auto { data-hi } else { y-max }
  if lo == hi {
    lo = lo - 1
    hi = hi + 1
  }
  // Padding only when the bound was inferred from the data.
  let ylo = if y-min == auto { lo - (hi - lo) * 0.08 } else { lo }
  let yhi = if y-max == auto { hi + (hi - lo) * 0.08 } else { hi }

  let px(v) = (v - x-min) / (x-max - x-min) * width
  let py(v) = (yhi - v) / (yhi - ylo) * height

  let body = ()
  let span = x-max - x-min
  let raw-step = span / calc.max(ticks, 1)
  let mag = calc.pow(10, calc.floor(calc.log(calc.max(raw-step, 1e-12), base: 10)))
  let norm = raw-step / mag
  let nice = if norm <= 1 { 1 } else if norm <= 2 { 2 } else if norm <= 5 { 5 } else { 10 }
  let step = nice * mag
  let tv = calc.ceil(x-min / step) * step
  while tv <= x-max + 1e-12 {
    if grid {
      body.push(place(
        top + left,
        dx: 0pt,
        dy: 0pt,
        line(start: (px(tv), 0pt), end: (px(tv), height), stroke: 0.4pt + luma(190)),
      ))
    }
    let label = str(calc.round(tv, digits: 2))
    let lx = calc.min(px(tv) - label.len() * 1.9pt, width - label.len() * 3.8pt)
    body.push(place(top + left, dx: lx, dy: height - 14pt, text(size: 7.5pt, fill: luma(100), label)))
    tv = tv + step
  }
  for i in range(1, 5) {
    let yv = ylo + (yhi - ylo) * i / 5
    if grid {
      body.push(place(
        top + left,
        dx: 0pt,
        dy: 0pt,
        line(start: (0pt, py(yv)), end: (width, py(yv)), stroke: 0.4pt + luma(190)),
      ))
    }
    body.push(place(
      top + left,
      dx: 2pt,
      dy: py(yv) - 5pt,
      text(size: 7.5pt, fill: luma(100), str(calc.round(yv, digits: 2))),
    ))
  }
  if x-min < 0 and x-max > 0 {
    body.push(place(top + left, dx: 0pt, dy: 0pt, line(
      start: (px(0), 0pt),
      end: (px(0), height),
      stroke: 0.9pt + luma(90),
    )))
  }
  if ylo < 0 and yhi > 0 {
    body.push(place(top + left, dx: 0pt, dy: 0pt, line(
      start: (0pt, py(0)),
      end: (width, py(0)),
      stroke: 0.9pt + luma(90),
    )))
  }

  for spec in sampled {
    let comps = ()
    let started = false
    for pair in spec.at("pts") {
      let clamped = calc.min(calc.max(pair.at(1), ylo), yhi)
      let pt = (px(pair.at(0)), py(clamped))
      if started {
        comps.push(curve.line(pt))
      } else {
        comps.push(curve.move(pt))
        started = true
      }
    }
    if comps.len() > 1 {
      body.push(place(top + left, dx: 0pt, dy: 0pt, curve(stroke: spec.at("stroke"), fill: none, ..comps)))
    }
  }

  let labeled = sampled.filter(s => s.at("label") != none)
  if legend != none and labeled.len() > 0 {
    let ly = if title != none { 20pt } else { 6pt } // stay clear of the title
    for spec in labeled {
      body.push(place(
        top + left,
        dx: width - 76pt,
        dy: ly,
        text(size: 9pt, fill: spec.at("stroke"), spec.at("label")),
      ))
      ly = ly + 12pt
    }
  }
  if title != none {
    body.push(place(top + center, dy: 2pt, text(size: 10pt, weight: "bold", title)))
  }
  box(
    width: width,
    height: height,
    stroke: if border { 0.5pt + luma(140) } else { none },
    body.join(),
  )
}
