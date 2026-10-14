# d4-plot

A native desktop viewer for D4 genomic signal files. D4 Plot compares multiple
tracks, displays genomic annotations, exports visible bins, and creates coverage
D4 files from BAM or CRAM.

<img width="519" height="398" src="https://github.com/user-attachments/assets/4764c1b7-2147-476a-8e57-8da2e6cf81fb" alt="D4 Plot window" />

## Documentation

[English guide](https://kojix2.github.io/d4-plot/books/guide_en/) ·
[日本語ガイド](https://kojix2.github.io/d4-plot/books/guide_ja/)

## Install

Download a package from [GitHub Releases](https://github.com/kojix2/d4-plot/releases),
or follow the [source build guide](https://kojix2.github.io/d4-plot/books/guide_en/installation.html).

## Development

```sh
shards install --frozen
crystal spec spec
ameba
crystal tool format --check src spec examples
```

See the [development guide](https://kojix2.github.io/d4-plot/books/guide_en/development.html)
for native dependencies, platform-specific builds, and UI runtime constraints.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
