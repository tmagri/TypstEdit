# CAS helper (`typstedit-cas`)

Calculator mode is powered by [Giac](https://www-fourier.ujf-grenoble.fr/~parisse/giac/)
— the C++ computer-algebra engine behind Xcas and the HP Prime calculator —
compiled into a small line-oriented helper program that TypstEdit runs as a
subprocess (the same pattern as the bundled `typst` compiler).

## Building

```sh
Tools/cas/build_cas.sh                  # this machine's architecture
Tools/cas/build_cas.sh --arch universal # arm64 + x86_64, merged with lipo
Tools/cas/build_cas.sh fetch            # just download/verify pinned sources
```

The script (needs Xcode CLT, plus Homebrew `autoconf automake libtool bash`
on macOS) downloads pinned sources of GMP 6.3.0, MPFR 4.2.2 and Giac (Debian
salsa commit `5295d5d`), applies Debian's build patches, builds static
libraries per architecture under `build/cas/prefix-<arch>`, and links the
helper from `typstedit-cas.cpp` into `build/cas/typstedit-cas`. `bundle.sh`
copies that binary into `Contents/Resources/bin/`.

First build takes roughly 20–40 minutes per architecture (GMP + MPFR + Giac).
Incremental rebuilds after editing `typstedit-cas.cpp` take seconds.

## How TypstEdit uses it

`CASEngine.swift` starts one helper per app and speaks JSON lines:

```
request  {"v":1,"id":N,"op":"eval","input":"solve(x^2-4=0,x)","approx":false,
          "angle":"rad","digits":12}
reply    {"v":1,"id":N,"ok":true,"inputTree":{…},"resultTree":{…},
          "resultText":"(x=-2) or (x=2)"}
```

Other ops: `reset` (drop stored variables) and `shutdown`. Interruption: the
app sends SIGINT; giac's handler aborts the running eval, which comes back as
`{"ok":false,"error":"Interrupted","errorKind":"interrupt"}`.

- The helper starts giac in **TI-89 compatibility mode** (`xcas_mode == 3`),
  so `solve`, `zeros`, `cZeros`, `nDeriv`, `csolve`, `[a,b;c,d]` matrices,
  `d(`, `∫(` and `►` store work natively.
- Result trees are structural JSON (`{"t":"op","name":"+","args":[…]}`), so
  Swift never parses printed text; `CASTypstRenderer` turns trees into Typst
  math for insertion and export.
- TI-89 spellings giac doesn't carry (`d(` → `diff(`, `→` → `►`,
  `cSolve(` → `csolve(`, `ans`/`entry(n)` recall) are handled in Swift by
  `TISyntax.swift`.

## Licensing

Giac is GPL-3.0-or-later; GMP and MPFR are LGPL-3.0. They are linked only
into this helper program, which runs as a separate process from the MIT-licensed
TypstEdit app. See `THIRD_PARTY_NOTICES.md`.
