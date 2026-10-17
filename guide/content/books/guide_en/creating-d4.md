# Creating D4 files

Choose **Create D4** and provide:

- a coordinate-sorted BAM with a BAI or CSI index, or a CRAM with a CRAI index;
- for CRAM, the matching reference FASTA and its `.fai` index; and
- a new output filename ending in `.d4`.

The **Basic settings** tab selects the files and coverage mode. **Advanced
settings** provides minimum MAPQ, include and exclude SAM flags, read-group
selection, absolute template-length limits, and BAM/CRAM decompression threads.
The default excluded flags are unmapped, secondary, QC-failed, and duplicate
reads (`0x704`); supplementary alignments are not excluded by default.

![Create D4 dialog with synthetic BAM input and D4 output paths](../../screenshots/en/create-d4.png)

The example input is synthetic; choose your own indexed BAM or CRAM file.

## Before you begin

Prepare the alignment file and its index before opening the dialog. The BAM or
CRAM should be coordinate-sorted, and the reference assembly should be the one
you intend to compare with other samples and annotations. A successful
conversion cannot correct an assembly mismatch.

For a first coverage track, **Standard** is usually the easiest choice. Use
**Fast** when you need a quick broad inspection and **Fragments** when the
biological question concerns paired-template or fragment spans.

## What the advanced settings mean

- **MAPQ** is the mapper's confidence in an alignment. A higher minimum keeps
  only more confidently placed reads.
- **Include and exclude flags** choose categories of SAM records. The default
  excludes unmapped, secondary, QC-failed, and duplicate reads. Keep the
  default unless your analysis protocol calls for a different policy.
- **Read group** is useful when one BAM contains several libraries or samples
  and you want to make a track from only one group.
- **Template length** filters paired reads by the absolute insert/template
  length. Leave it unset unless this is part of your protocol.
- **Threads** changes how many decompression workers are used. It can change
  conversion time, but not the intended coverage definition.

## Coverage modes

- **Standard — aligned bases:** respects CIGAR gaps and counts overlapping
  mates once.
- **Fast — whole read spans:** includes CIGAR gaps and counts overlapping mates
  twice.
- **Fragments — paired templates:** counts proper paired-template spans,
  including the insert.

Choose **Create D4** to begin conversion. The viewer remains usable while it
runs. After completion, check the output path and reference assembly, then
choose **Add to view** to show the new track alongside the current ones. The
D4 file remains saved at the selected path even if you do not add it to the view.

D4 Plot builds secondary-frame and sum indexes, verifies the completed file,
and only then publishes it at the requested path. It never replaces an existing
destination. Cancelling or failing before publication removes the temporary
result and leaves the current view unchanged.
