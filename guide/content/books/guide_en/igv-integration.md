# IGV integration

D4 Plot can send the current locus to IGV Desktop or display D4 tracks in its
local IGV.js viewer. These are separate features.

| Action | What it does | Requirement |
| --- | --- | --- |
| **IGV → View region in IGV Desktop** | Moves an already-running IGV Desktop to the current locus | IGV Desktop must accept external control on `127.0.0.1:60151` |
| **IGV → Open D4 tracks in IGV.js…** | Shows the current D4 tracks in a browser | Open at least one D4 track |
| `d4-plot serve` / `d4-plot-server` | Serves the same IGV.js viewer without the native GUI | Provide at least one D4 file |

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

## View D4 tracks in IGV.js

1. Open D4 tracks in D4 Plot and choose **IGV → Open D4 tracks in IGV.js…**.
2. In the browser, select a reference. If needed, select tracks under **D4
   tracks** and click **Load selected tracks**.
3. Navigate and zoom in the browser. D4 Plot calculates mean D4 values for
   the requested intervals at the display resolution.

| Item | Behavior |
| --- | --- |
| Initial locus | Uses the visible D4 Plot locus; falls back to a valid locus if it does not fit the selected reference. |
| Tracks | Selects the first 12 tracks by default; choose others under **D4 tracks**. |
| Reference | Starts with D4-derived **Contigs only**; the browser can switch to `hg38`, `hg19`, `hs1`, or `mm39`. |
| Gene annotations | Public presets load an assembly-matched gene track automatically: GENCODE for `hg38`, `hg19`, and `mm39`; NCBI RefSeq for `hs1`. Contigs only and local references have no automatic gene track. |
| D4 values | Displays means over resolution-dependent bins. Zoom in to inspect narrow peaks. |
| Connection | Binds only to `127.0.0.1`. The URL contains a session token; do not publish it. |

Reference choices have different data and privacy implications:

| Choice | Sequence data | Consideration |
| --- | --- | --- |
| **Contigs only** | D4 contig names and lengths only | No bases are available. A D4-derived dictionary does not verify which assembly produced the D4 file. |
| Public preset | Fetched from public IGV/UCSC hosts | Requires network access; the reference and approximate viewed intervals may be visible to those hosts. |
| Local FASTA / IGV genome JSON | Uses a local FASTA and FAI | Specify it through the CLI below for fully local reference access. |

The browser's **View locus in IGV Desktop** button is available only when the
selected reference has a contig dictionary and the browser shows one locus.
Public presets do not have a verified dictionary, so the button is disabled
for them. It sends only the locus; it does not change IGV Desktop's assembly.

## Run without the native GUI

`d4-plot serve` and `d4-plot-server` accept the same options:

```sh
d4-plot serve --genome hg38 --open sample.d4
d4-plot-server --reference reference.fa --reference-index reference.fa.fai sample.d4
d4-plot-server --contigs-only sample.d4
```

| Option | Purpose |
| --- | --- |
| `--genome ID` | Select a public preset. |
| `--reference PATH` | Select a local FASTA or IGV genome JSON. A FASTA needs an existing FAI. |
| `--reference-index PATH` | Name a FAI at a non-default path. |
| `--contigs-only` | Use D4 contig names and lengths. This is also the default. |
| `--region REGION` | Set the initial locus, for example `chr1:100-200`. |
| `--open` | Open a browser automatically; the server remains running if launching the browser fails. |
| `--port PORT` | Set the loopback port. The default `0` chooses an available port. |

- `--genome`, `--reference`, and `--contigs-only` are mutually exclusive.
- Open the printed URL in a browser on the **same computer**.
- Stop the server with Ctrl-C.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Cannot reach IGV Desktop | Check that IGV Desktop is running and accepts external control on `127.0.0.1:60151`. D4 Plot does not start it. |
| No tracks in the browser | Check the **D4 tracks** selection and whether D4 contig names and lengths match the selected reference. |
| A public preset does not load | Check network access, or start the server with a local FASTA/FAI. |
| An older browser tab stops working | After changing D4 Plot tracks, reopen it with **IGV → Open D4 tracks in IGV.js…**. |
| `HTTP::Client::Response#body_io cannot be nil` | An older build mishandles a bodyless IGV Desktop response. Update to a build containing the fix, or rerun `shards build d4-plot` for a source build. |
