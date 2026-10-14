# Installation

## Release packages

[GitHub Releases](https://github.com/kojix2/d4-plot/releases) provides the
packages produced by the release workflow:

- a portable ZIP and an installer for 64-bit Windows;
- application bundles for Apple Silicon and Intel macOS; and
- an AMD64 Debian package for Ubuntu and compatible systems.

## Build from source

D4 Plot requires Crystal 1.21 or later, Shards, Git,
[UIng's native dependencies](https://kojix2.github.io/uing/books/guide_en/installation.html),
HTSlib, and pkg-config.

On macOS, install the alignment dependencies with:

```sh
brew install htslib pkg-config
```

On Debian or Ubuntu, install them with:

```sh
sudo apt install libhts-dev pkg-config
```

Then build D4 Plot:

```sh
git clone https://github.com/kojix2/d4-plot.git
cd d4-plot
shards install --frozen
shards build --release
```

Windows builds use MSYS2 UCRT64 and a statically linked HTSlib. The exact
packages are listed in the
[Windows setup action](https://github.com/kojix2/d4-plot/blob/main/.github/actions/setup-windows/action.yml).
From that environment, run:

```sh
shards install --frozen
bash scripts/build-windows.sh
```

## Starting the application

Pass one or more D4 files, and optionally an initial region or interface
language:

```sh
bin/d4-plot sample.d4
bin/d4-plot --region chr1:1,000,000-2,000,000 sample1.d4 sample2.d4
bin/d4-plot --locale ja sample.d4
```

Use `bin/d4-plot --help` to list the supported language codes. On Windows the
source-build executable is `bin/d4-plot.exe`.
