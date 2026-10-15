# IGV.js vendor files

`manifest.json` is the sole version and integrity record for the local IGV.js
bundle. The application must serve `igv.min.js` from this directory only; it
must not substitute a CDN copy when the file is absent.

To fetch the exact pinned package, without running package lifecycle scripts:

```sh
node scripts/update-igv.mjs
```

To move to an exact new release, pass `--version <semver>`. The update command
uses `npm pack`, checks the npm tarball's SRI and SHA-1 metadata, extracts only
the bundle and license, syntax-checks the JavaScript, and atomically updates
the manifest hashes. Before compiling or releasing the web viewer, run:

```sh
node scripts/verify-igv.mjs
```

The bundle is intentionally not generated at application runtime. If it is
missing, verification (and the web server) must fail with an instruction to
run the update command; no browser request may fall back to a CDN.
