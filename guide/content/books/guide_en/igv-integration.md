# IGV integration

| Task | Action |
| --- | --- |
| Send the current locus to an existing IGV Desktop session | **IGV → View region in IGV Desktop** |
| View D4 with BAM/CRAM, VCF, BED, GTF, or BigWig | **IGV → Open genome browser (IGV.js)…** |
| Run the browser viewer without the desktop app | [`d4-plot serve` or `d4-plot-server`](command-line.md) |

## IGV Desktop

1. Start IGV Desktop with the same reference assembly as the D4.
2. Navigate to a locus in D4 Plot.
3. Choose **IGV → View region in IGV Desktop**.

D4 Plot sends only the locus to `127.0.0.1:60151`. It does not start IGV Desktop, change its assembly, or load tracks. Confirm the assembly in both apps; D4 metadata cannot verify it.

## IGV.js browser

Choose **IGV → Open genome browser (IGV.js)…**. The browser can start without D4. Select a reference, then choose D4 tracks under **D4 tracks** and click **Apply selection**. The first 12 tracks are selected initially; you can deselect all of them.

Use **Add track** to open a local file or URL. Supply an index for formats that require one; set Format or Track type if IGV.js cannot infer it. Added local files must be selected again after a reference or D4 selection change, or a page reload. Remote URLs need browser access, CORS for other origins, and HTTP Range for indexed data.

| Reference | Behavior |
| --- | --- |
| **Contigs only** | Default with D4. Names and lengths only; no bases or verified assembly. |
| `hg38`, `hg19`, `hs1`, `mm39`, `mm10`, `rn7`, `danRer11`, `dm6`, `ce11`, `sacCer3` | Public presets. The browser fetches reference data from UCSC, which may learn the reference and approximate viewed intervals. |
| Local FASTA/FAI or IGV genome JSON | Select through the [server CLI](command-line.md) for local reference access. |

Without D4, the browser starts with `hg38`. Public presets add an assembly-matched gene track: GENCODE for `hg38`, `hg19`, `mm39`, and `mm10`; NCBI RefSeq for `hs1` and the five additional species. Contigs only and local references add none. Added tracks must match the reference's contig names and assembly. CRAM needs sequence bases.

D4 requests contain at most 1024 bins. With a usable sum index, bin means are exact. Wide ranges without one may use sampled means and miss narrow peaks; zoom in or add a sum index.

The server binds to `127.0.0.1`. Its URL contains a session token; do not publish it. The browser's **View locus in IGV Desktop** button requires a reference with a verified contig dictionary and one locus. It sends only the locus.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| IGV Desktop does not respond | It is running and accepts control on `127.0.0.1:60151`. |
| D4 is missing | **D4 tracks** selection and reference contig names/lengths. |
| Added track is missing | Format, index, assembly, and, for URLs, CORS/HTTP Range. |
| Public preset fails | Network access; use local FASTA/FAI if needed. |
| Old browser tab fails after track changes | Reopen the browser from D4 Plot. |
