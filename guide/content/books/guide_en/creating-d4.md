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

## Coverage modes

- **Standard — aligned bases:** respects CIGAR gaps and counts overlapping
  mates once.
- **Fast — whole read spans:** includes CIGAR gaps and counts overlapping mates
  twice.
- **Fragments — paired templates:** counts proper paired-template spans,
  including the insert.

The conversion runs on an isolated worker while the viewer remains usable.
D4 Plot builds secondary-frame and sum indexes, verifies the completed file,
and only then publishes it at the requested path. It never replaces an existing
destination. Cancelling or failing before publication removes the temporary
result and leaves the current view unchanged.
