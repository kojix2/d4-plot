# Viewing tracks

## Opening files

**Open D4** replaces the current tracks and annotation. **Add D4** keeps the
current view and appends tracks. Both file dialogs accept multiple files, and
each track contained in a D4 file is added separately.

File metadata is checked in the background before the new selection is
applied. Cancelling or encountering an invalid file keeps the previous view.
Files may have different chromosome sets, but a chromosome appearing in more
than one track must have the same length.

D4 metadata does not establish which reference assembly produced a file.
Matching chromosome names and lengths are therefore not proof that tracks use
the same assembly; verify their provenance before comparison.

## Regions and navigation

The region field accepts:

- `chr1:100-200` for a range;
- `chr1:100` for one base; or
- `chr1` for the whole chromosome.

Use the mouse or toolbar to navigate:

- drag to pan;
- Shift-drag to select a range;
- double-click to zoom in;
- right-click to zoom out;
- click the chromosome overview to jump; and
- use **Back** and **Forward** to revisit regions.

When the plot has keyboard focus, Left and Right pan by half a view, `+` and
`-` zoom, Home shows the whole chromosome, and Escape cancels a drag or an
active load.

## Managing the display

Select a track by its title or in the track list. The list can show, hide,
reorder, or remove tracks without deleting their files. **Shared Y** gives all
visible tracks one scale. **Height** changes track row height, and the track
sidebar can be hidden to give the plot more space.

The **Settings** window controls the number of bins, automatic or fixed Y scale,
whether automatic scaling includes zero, reference lines, signal color,
annotation limit, and toolbar labels.
