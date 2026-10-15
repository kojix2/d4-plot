#!/usr/bin/env node
import { readManifest, verifyVendoredIgv } from "./igv-vendor.mjs";

try {
  if (process.argv.length !== 2) throw new Error("Usage: node scripts/verify-igv.mjs");
  const verified = verifyVendoredIgv(readManifest());
  console.log(`Verified IGV.js ${verified.version} (${verified.bytes} bytes).`);
} catch (error) {
  const detail = error instanceof Error ? error.message : String(error);
  console.error(`IGV.js verification failed: ${detail}`);
  process.exitCode = 1;
}
