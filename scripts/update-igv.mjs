#!/usr/bin/env node
import { rmSync } from "node:fs";
import {
  BUNDLE_PATH,
  LICENSE_PATH,
  assertExactVersion,
  assertJavaScriptSyntax,
  makeUpdatedManifest,
  packExactNpmPackage,
  readManifest,
  relativeToRoot,
  unpackIgvArtifacts,
  verifyVendoredIgv,
  writeFileAtomically,
  writeManifestAtomically,
} from "./igv-vendor.mjs";

function usage() {
  console.log("Usage: node scripts/update-igv.mjs [--version <exact-semver>]");
  console.log("Without --version, refreshes the exact version pinned in vendor/igv/manifest.json.");
}

function requestedVersion(argumentsList, fallback) {
  let version = fallback;
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === "--help" || argument === "-h") return null;
    if (argument === "--version") {
      index += 1;
      if (index >= argumentsList.length) throw new Error("--version requires an exact SemVer value");
      version = argumentsList[index];
      continue;
    }
    if (argument.startsWith("--version=")) {
      version = argument.slice("--version=".length);
      continue;
    }
    throw new Error(`Unknown argument: ${argument}`);
  }
  return assertExactVersion(version, "Requested version");
}

function main() {
  const manifest = readManifest();
  const version = requestedVersion(process.argv.slice(2), manifest.package.version);
  if (version === null) {
    usage();
    return;
  }

  const packageInfo = { ...manifest.package, version };
  const { metadata, tarball } = packExactNpmPackage(packageInfo);
  const { bundle, license } = unpackIgvArtifacts(tarball, packageInfo);
  const updatedManifest = makeUpdatedManifest(manifest, version, metadata, bundle, license);

  // Parse the candidate before replacing the last known-good bundle.  If this
  // process is interrupted during the following individual atomic renames,
  // `verify-igv.mjs` fails closed rather than accepting a mixed vendor state.
  const candidatePath = `${BUNDLE_PATH}.candidate.js`;
  try {
    writeFileAtomically(candidatePath, bundle);
    assertJavaScriptSyntax(candidatePath);
    writeFileAtomically(BUNDLE_PATH, bundle);
    writeFileAtomically(LICENSE_PATH, license);
    writeManifestAtomically(updatedManifest);
  } finally {
    // The candidate is an update-only temporary artifact and must never be
    // mistaken for a distributable bundle.
    rmSync(candidatePath, { force: true });
  }

  const verified = verifyVendoredIgv(updatedManifest);
  console.log(`Updated ${relativeToRoot(BUNDLE_PATH)} from igv@${verified.version} (${verified.bytes} bytes).`);
}

try {
  main();
} catch (error) {
  const detail = error instanceof Error ? error.message : String(error);
  console.error(`IGV.js update failed: ${detail}`);
  process.exitCode = 1;
}
