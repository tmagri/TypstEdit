# Third-Party Notices

Notices for third-party components TypstEdit distributes or bundles. Each
entry lists the component, its source, its license, and — where required —
the license text itself (collected at the end of this file).

| Component | Role in TypstEdit | License |
|---|---|---|
| Typst engine (`typst` binary) | Bundled compiler, also updated in-app | Apache 2.0 |
| Giac CAS (`typstedit-cas` helper) | Bundled CAS engine for Calculator mode | **GPL-3.0** (separate program) |
| GMP (`libgmp`) | Linked into the `typstedit-cas` helper only | LGPL-3.0 (statically linked) |
| MPFR (`libmpfr`) | Linked into the `typstedit-cas` helper only | LGPL-3.0 (statically linked) |
| CodeEditSourceEditor | Editor component | MIT |
| CodeEditTextView | Editor component | MIT |
| CodeEditLanguages | Syntax highlighting (tree-sitter grammars) | *see note* — grammars are MIT/BSD upstream |
| SwiftTreeSitter | Swift bindings for tree-sitter | BSD 3-Clause |
| tree-sitter | Parsing library | MIT |
| tree-sitter-typst | Typst grammar | MIT |
| TextFormation | Text input rules | BSD 3-Clause |
| TextStory | Text interfaces | BSD 3-Clause |
| Rearrange | Range utilities | BSD 3-Clause |
| swift-collections | Swift data structures | Apache 2.0 |
| SQLite (`sqlite3.c` amalgamation) | Embedded database | Public domain |
| sqlite-vector (`vector.framework`) | Vector search for RAG | Apache 2.0 |
| swift-markdown / swift-cmark | Markdown parsing | Apache 2.0 |
| MathLive (`mathlive.min.js`) | Equation editor (vendored JS) | MIT |
| tex2typst (`tex2typst.min.js`) | LaTeX↔Typst math conversion (vendored JS) | Apache 2.0 |
| LLMLingua-2 model | Optional AI compression model | Apache 2.0 |
| SwiftLintPlugin, `llmlingua`/`torch`/`transformers`/`coremltools` | Build/development tools only, **never shipped** | MIT / (varies) |

---

## Typst engine

The bundled `typst` binary (`Contents/Resources/bin/typst`) is built from
[typst/typst](https://github.com/typst/typst), © The Typst Authors,
**Apache License 2.0** (full text at the end of this file). The in-app
updater replaces it with official release builds of the same project.

## CAS helper (Calculator mode)

The bundled `typstedit-cas` helper (`Contents/Resources/bin/typstedit-cas`)
embeds [Giac](https://www-fourier.ujf-grenoble.fr/~parisse/giac/),
© Bernard Parisse and others, **GNU GPL-3.0-or-later**. TypstEdit talks to it
as a separate program over stdin/stdout (see `Tools/cas/typstedit-cas.cpp`,
the helper's source, and `Tools/cas/build_cas.sh`, which fetches and builds
Giac plus GMP and MPFR from pinned sources). Because Giac runs as its own
process, this file, and TypstEdit itself, remain under MIT; the GPL applies
to the helper program.

- **Giac** — GPL-3.0-or-later. Full text: <https://www.gnu.org/licenses/gpl-3.0.html>
- **GMP** (statically linked into the helper only) — LGPL-3.0. Full text:
  <https://www.gnu.org/licenses/lgpl-3.0.html>
- **MPFR** (statically linked into the helper only) — LGPL-3.0.
- macOS **Accelerate** framework (system, not distributed).

Source-code offers: the exact Giac/GMP/MPFR versions used are pinned and
downloaded by `Tools/cas/build_cas.sh` (Giac commit
`5295d5d9144e3b9837cd257ec36a83c07a0ddbbe`, GMP 6.3.0, MPFR 4.2.2), so the
complete corresponding source for the bundled helper can be produced with:
`Tools/cas/build_cas.sh fetch && Tools/cas/build_cas.sh`.

## Editor components

**CodeEditSourceEditor** — <https://github.com/CodeEditApp/CodeEditSourceEditor>,
MIT License, © 2022 CodeEdit. Vendored under `LocalPackages/`.

**CodeEditTextView** — <https://github.com/CodeEditApp/CodeEditTextView>,
MIT License, © 2023 CodeEdit. Vendored under `LocalPackages/`.

**CodeEditLanguages** — <https://github.com/CodeEditApp/CodeEditLanguages>.
The wrapper Swift sources are authored by the CodeEdit project
(Lukas Pistrol, Khan Winter); the upstream repository does not currently
include a license file — *status to be confirmed with upstream*. The
shipped `CodeLanguagesContainer.xcframework` embeds
[tree-sitter](https://tree-sitter.github.io/) grammar packages, which carry
their own permissive licenses (MIT/BSD) in their upstream repositories.

**SwiftTreeSitter** — <https://github.com/ChimeHQ/SwiftTreeSitter>,
BSD 3-Clause, © 2021 Chime.

**tree-sitter** — <https://github.com/tree-sitter/tree-sitter>,
MIT License, © 2018-2024 Max Brunsfeld.

**tree-sitter-typst** — Typst grammar for tree-sitter,
MIT License, © 2023 Gerbais-Nief Eddie.

**TextFormation** — <https://github.com/ChimeHQ/TextFormation>,
BSD 3-Clause, © 2022 Chime.

**TextStory** — <https://github.com/ChimeHQ/TextStory>,
BSD 3-Clause, © 2020 Chime.

**Rearrange** — <https://github.com/ChimeHQ/Rearrange>,
BSD 3-Clause, © 2019 Chime Systems Inc.

**swift-collections** — <https://github.com/apple/swift-collections>,
© Apple Inc., Apache License 2.0 (full text at the end of this file).

## Search & data

**SQLite** — the `sqlite3.c`/`sqlite3.h` amalgamation vendored under
`LocalPackages/CSQLite` is SQLite, which is **public domain**: the authors
disclaim all copyright ("The author disclaims copyright to this source
code. In place of a legal notice, here is a blessing…"). No attribution
is required; this notice is courtesy.

**sqlite-vector** — <https://github.com/sqliteai/sqlite-vector> by SQLite AI,
the `vector.framework` bundled into the app for on-device semantic search
(RAG), **Apache License 2.0** (full text at the end of this file).

**swift-markdown / swift-cmark** — <https://github.com/apple/swift-markdown>,
© Apple Inc., Apache License 2.0 (full text at the end of this file).

## Vendored JavaScript (`Sources/Resources/Vendor`)

**MathLive 0.101.0** — <https://github.com/arnog/MathLive>,
MIT License, © 2017–present Arno Gourdol. Powers the equation editor.

**tex2typst** — <https://github.com/qwinsi/tex2typst>,
Apache License 2.0 (full text at the end of this file).
Converts LaTeX math to Typst math.

## LLMLingua-2 compression model (optional download)

- **What**: `LLMLingua2.mlpackage` + `vocab.txt` — a Core ML conversion of
  Microsoft's token-classification model for prompt compression, downloaded
  on demand from the TypstEdit model releases and run locally.
- **Source model**: [`microsoft/llmlingua-2-bert-base-multilingual-cased-meetingbank`](https://huggingface.co/microsoft/llmlingua-2-bert-base-multilingual-cased-meetingbank)
  by Microsoft, licensed under the **Apache License 2.0**.
- **Base model**: [`google-bert/bert-base-multilingual-cased`](https://huggingface.co/google-bert/bert-base-multilingual-cased)
  (including the tokenizer vocabulary `vocab.txt`), Apache License 2.0.
- **Modifications**: converted from the original PyTorch/safetensors
  checkpoint to an Apple Core ML package (float16, fixed 512-token input
  window) using `Tools/convert_llmlingua2_coreml.py` in this repository.
  The numerical outputs match the original within float16 tolerance; no
  weights were retrained.
- **Paper**: "LLMLingua-2: Data Distillation for Efficient and Faithful
  Task-Agnostic Prompt Compression" (Pan et al., 2024),
  <https://arxiv.org/abs/2403.12968>.
- **Not distributed**: the `llmlingua` Python package itself (MIT,
  <https://github.com/microsoft/LLMLingua>) and the conversion toolchain
  (`torch`, `transformers`, `coremltools`) are development-time only and
  never ship with the app.
- **Training data note**: the model was trained by Microsoft on
  `microsoft/MeetingBank-LLMCompressed` (seed data: MeetingBank, Hu et al.,
  2023). Those dataset licenses govern the datasets, not these model
  weights; listed here for completeness.

## Development-only components (not distributed)

**SwiftLintPlugin** (MIT, © 2022 Lukas Pistrol) is a SwiftPM build plugin
and runs only at compile time. Likewise the Python conversion toolchain for
the Core ML model never reaches the app bundle.

---

# License Texts

## MIT License (CodeEditSourceEditor — © 2022 CodeEdit; CodeEditTextView — © 2023 CodeEdit)

```text
MIT License

Copyright (c) 2022 CodeEdit

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

(The CodeEditTextView copy is identical except "© 2023 CodeEdit".)

## MIT License (tree-sitter — © 2018-2024 Max Brunsfeld)

```text
The MIT License (MIT)

Copyright (c) 2018-2024 Max Brunsfeld

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## MIT License (tree-sitter-typst — © 2023 Gerbais-Nief Eddie)

```text
MIT License

Copyright (c) 2023 Gerbais-Nief Eddie

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## MIT License (MathLive — © 2017–present Arno Gourdol)

```text
Copyright (c) 2017 - present Arno Gourdol. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## BSD 3-Clause License (Chime components)

Applies to SwiftTreeSitter (© 2021 Chime), TextFormation (© 2022 Chime),
TextStory (© 2020 Chime), and Rearrange (© 2019 Chime Systems Inc. — this
one uses a bulleted equivalent of the same numbered conditions):

```text
BSD 3-Clause License

Copyright (c) 2021, Chime
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

(Each Chime component substitutes its own copyright year/holder line.)

## Apache License 2.0

Applies to: the Typst engine, swift-collections, sqlite-vector,
swift-markdown/swift-cmark, tex2typst, and the LLMLingua-2 model
(© 2024 Microsoft Corporation). The full text follows.

```text

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

```
