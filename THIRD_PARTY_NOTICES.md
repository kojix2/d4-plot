# Third-party notices

## Conversion and GUI dependencies

D4 creation uses [mopdepth](https://github.com/kojix2/mopdepth) (MIT),
[hts.cr](https://github.com/bio-cr/hts.cr) (MIT) and native
[HTSlib](https://github.com/samtools/htslib) (MIT/Expat and Modified BSD).
[d4.cr](https://github.com/kojix2/d4.cr) supplies the D4 writer and reader, and
[UIng](https://github.com/kojix2/uing) supplies native GUI bindings (both MIT).
Exact Crystal dependency revisions are recorded in `shard.lock`.

Packaging scripts copy the dependency license texts into a `licenses` directory.
Windows packages also include HTSlib/htscodecs licenses, the installed MSYS2
license collection, and a package-version inventory for native dependencies.
Native dependencies retain their own licenses; d4-plot's MIT license does not
replace them. MSYS2 package sources are available from
<https://packages.msys2.org/>; HTSlib's Windows build is pinned in
`scripts/build-windows.sh`.

## Test fixtures

`spec/fixtures/rust-input-10nt.d4` and `spec/fixtures/rust-multitrack.d4` come from [d4-format](https://github.com/38/d4-format). The upstream license is reproduced below.

The MIT License (MIT)

Copyright (c) 2020-2022 Hao Hou<haohou302@gmail.com>

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
