# Introduction

D4 Plot is a cross-platform native desktop application for exploring
[D4](https://github.com/38/d4-format) genomic signal files. It can:

- display and compare multiple D4 tracks;
- overlay GFF3, GTF, or BED annotations;
- export the visible bins of a selected track as bedGraph; and
- create indexed coverage D4 files from BAM or CRAM alignments.

This guide is written for people who work with genomic data rather than
software development. You can use the normal workflow entirely through the
graphical interface. Start with [Start here](quick-start.md), then return to
the topic that matches your task.

## What you see in the plot

The viewer divides the selected genomic region into display bins. Each plotted
value is the mean signal for one bin, with any scaling stored in the D4 file
applied. It is not necessarily the measurement at one base. A broad flat-looking
region can therefore contain local variation. Zoom in before interpreting a
narrow peak or comparing a small feature.

## Three common tasks

- **Inspect an existing result:** open one or more D4 files and navigate to a
  gene, variant, or region of interest.
- **Compare samples:** add tracks, confirm that they use the same reference
  assembly, and enable **Shared Y** when visual height should be comparable.
- **Create or document a result:** create a D4 from BAM/CRAM, add a matching
  annotation file, then export displayed bins or an SVG plot.

The D4 format does not identify the reference assembly that produced it. Treat
assembly and chromosome-name verification as part of the scientific workflow,
not as something the viewer can infer automatically.

The viewer uses **1-based, inclusive** genomic coordinates. A region such as
`chr1:100-200` therefore contains 101 bases. Commas are accepted in positions.
Exported bedGraph intervals use **0-based, half-open** coordinates, so convert
them when comparing positions with the viewer.
