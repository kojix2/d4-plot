# Installation

Download the package for your system from [GitHub Releases](https://github.com/kojix2/d4-plot/releases):

- Windows x64: portable ZIP or installer
- macOS: Apple Silicon or Intel app bundle
- Ubuntu/compatible AMD64: Debian package

Install it and start **D4 Plot**. Release packages do not require Crystal or Shards. The Debian package installs declared runtime dependencies; Windows and macOS packages include native libraries.

## Build from source

Install Crystal 1.21+, Shards, Git, [UIng's native dependencies](https://kojix2.github.io/uing/books/guide_en/installation.html), HTSlib, and pkg-config.

```sh
# macOS
brew install htslib pkg-config

# Debian/Ubuntu
sudo apt install libhts-dev pkg-config
```

Then build:

```sh
git clone https://github.com/kojix2/d4-plot.git
cd d4-plot
shards install --frozen
shards build --release
```

On Windows, use MSYS2 UCRT64 with the packages in the [setup action](https://github.com/kojix2/d4-plot/blob/main/.github/actions/setup-windows/action.yml), then run:

```sh
shards install --frozen
bash scripts/build-windows.sh
```

## Start from a terminal

```sh
bin/d4-plot sample.d4
bin/d4-plot --region chr1:1,000,000-2,000,000 sample1.d4 sample2.d4
bin/d4-plot --locale ja sample.d4
```

Use `bin/d4-plot --help` for language codes. On Windows, the source-build executable is `bin/d4-plot.exe`. See [Start here](quick-start.md) for the UI workflow.
