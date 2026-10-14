# Introduction

D4 Plot is a cross-platform native desktop application for exploring
[D4](https://github.com/38/d4-format) genomic signal files. It can:

- display and compare multiple D4 tracks;
- overlay GFF3, GTF, or BED annotations;
- export the visible bins of a selected track as bedGraph; and
- create indexed coverage D4 files from BAM or CRAM alignments.

The viewer uses **1-based, inclusive** genomic coordinates. A region such as
`chr1:100-200` therefore contains 101 bases. Commas are accepted in positions.

The plotted signal is sampled into display bins. Each point is the mean for its
bin after applying the D4 denominator; it is not necessarily a single-base
value. Zoom in when inspecting narrow peaks or local variation. Exported
bedGraph intervals use the format's conventional **0-based, half-open**
coordinates.
