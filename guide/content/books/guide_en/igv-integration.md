# IGV integration

D4 Plot can send the current locus to IGV Desktop or display D4 and other genome
tracks in its local IGV.js viewer. These are separate features.

| Action | What it does | Requirement |
| --- | --- | --- |
| **IGV → View region in IGV Desktop** | Moves an already-running IGV Desktop to the current locus | IGV Desktop must accept external control on `127.0.0.1:60151` |
| **IGV → Open genome browser (IGV.js)…** | Shows D4 and additional genome tracks in a browser | None; without D4 the browser starts with hg38 |
| `d4-plot serve` / `d4-plot-server` | Serves the same IGV.js viewer without the native GUI | Provide a D4 file, `--genome`, or `--reference` |

## Send a locus to IGV Desktop

1. Start IGV Desktop and select the same reference assembly as the D4 data.
2. Open a D4 track and navigate to the desired locus in D4 Plot.
3. Choose **IGV → View region in IGV Desktop**.

- D4 Plot sends **only the locus** through IGV Desktop's `/goto` command. It
  does not start IGV Desktop, change its genome, or load D4 tracks into it.
- The connection runs in the background. D4 Plot reports success in its status
  area and failure in an error dialog.
- D4 metadata alone cannot establish its reference assembly. Matching contig
  names and lengths do not prove that both applications use the same assembly.

## View D4 and other tracks in IGV.js

1. Choose **IGV → Open genome browser (IGV.js)…** in D4 Plot. You can start
   without a D4 file and add other tracks in the browser.
2. In the browser, select a reference. If needed, select tracks under **D4
   tracks** and click **Apply selection**. You can deselect every D4 track to
   view only the tracks you add.
3. Use **Add track** to add a local file or data URL. IGV.js can display BAM,
   CRAM, VCF, BED, GTF, GFF3, BigWig, and other supported formats beside D4.
   Supply an index when needed. If the format cannot be inferred from the name,
   enter a format or track type override.
4. Navigate and zoom in the browser. D4 uses at most 1024 bins per request.
   With a usable D4 sum index, bins show exact means even across a chromosome. For
   large ranges without a usable sum index, the browser may show bounded sampled means; zoom in
   for exact values or add a sum index to the D4 file.

| Item | Behavior |
| --- | --- |
| Initial locus | Uses the visible D4 Plot locus; falls back to a valid locus if it does not fit the selected reference. |
| Tracks | Selects the first 12 tracks by default; choose others under **D4 tracks**. |
| Added tracks | Use **Add track** with a local file or URL. Supply matching indexes for large BAM, CRAM, compressed VCF, and annotation files when available. |
| Reference | Starts with D4-derived **Contigs only** when D4 is open, otherwise `hg38`; the browser can switch to `hg38`, `hg19`, `hs1`, or `mm39`. |
| Gene annotations | Public presets load an assembly-matched gene track automatically: GENCODE for `hg38`, `hg19`, and `mm39`; NCBI RefSeq for `hs1`. Contigs only and local references have no automatic gene track. |
| D4 values | Uses up to 1024 resolution-dependent bins per request. Wide ranges without a usable sum index may use sampled means; narrow peaks can be missed. Zoom in for exact values. |
| Connection | Binds only to `127.0.0.1`. The URL contains a session token; do not publish it. |

Reference choices have different data and privacy implications:

| Choice | Sequence data | Consideration |
| --- | --- | --- |
| **Contigs only** | D4 contig names and lengths only | No bases are available. A D4-derived dictionary does not verify which assembly produced the D4 file. |
| Public preset | Fetched from public IGV/UCSC hosts | Requires network access; the reference and approximate viewed intervals may be visible to those hosts. |
| Local FASTA / IGV genome JSON | Uses a local FASTA and FAI | Specify it through the CLI below for fully local reference access. |

Added tracks must use contig names and an assembly that match the selected
reference. CRAM needs a reference with sequence data. The browser reads local
files directly; select them again after changing the reference or D4 selection,
or reloading the page. Remote data must be reachable from the browser.
Cross-origin servers need CORS, and indexed files need HTTP Range support.

The browser's **View locus in IGV Desktop** button is available only when the
selected reference has a contig dictionary and the browser shows one locus.
Public presets do not have a verified dictionary, so the button is disabled
for them. It sends only the locus; it does not change IGV Desktop's assembly.

## Run without the native GUI

`d4-plot serve` and `d4-plot-server` accept the same options:

```sh
d4-plot serve --genome hg38 --open sample.d4
d4-plot-server --genome hg38 --open
d4-plot-server --reference reference.fa --reference-index reference.fa.fai sample.d4
d4-plot-server --contigs-only sample.d4
```

| Option | Purpose |
| --- | --- |
| `--genome ID` | Select a public preset. |
| `--reference PATH` | Select a local FASTA or IGV genome JSON. A FASTA needs an existing FAI. |
| `--reference-index PATH` | Name a FAI at a non-default path. |
| `--contigs-only` | Use D4 contig names and lengths. This is the default when D4 is supplied without another reference. |
| `--region REGION` | Set the initial locus, for example `chr1:100-200`. |
| `--open` | Open a browser automatically; the server remains running if launching the browser fails. |
| `--port PORT` | Set the loopback port. The default `0` chooses an available port. |

- `--genome`, `--reference`, and `--contigs-only` are mutually exclusive.
- Without a D4 file, specify `--genome` or `--reference`.
- Open the printed URL in a browser on the **same computer**.
- Stop the server with Ctrl-C.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Cannot reach IGV Desktop | Check that IGV Desktop is running and accepts external control on `127.0.0.1:60151`. D4 Plot does not start it. |
| No tracks in the browser | Check the **D4 tracks** selection and whether D4 contig names and lengths match the selected reference. |
| An added track does not display | Check its format, index, and reference contig names. For a URL, also check CORS and HTTP Range support. |
| A public preset does not load | Check network access, or start the server with a local FASTA/FAI. |
| An older browser tab stops working | After changing D4 Plot tracks, reopen it with **IGV → Open D4 tracks in IGV.js…**. |
| `HTTP::Client::Response#body_io cannot be nil` | An older build mishandles a bodyless IGV Desktop response. Update to a build containing the fix, or rerun `shards build d4-plot` for a source build. |
