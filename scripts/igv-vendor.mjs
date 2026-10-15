/**
 * Shared, dependency-free helpers for the checked-in IGV.js distribution.
 *
 * `npm pack` is deliberately the only networked operation.  It receives an
 * exact version, does not run lifecycle scripts, and is unpacked in memory so
 * an archive cannot write arbitrary paths into this repository.
 */
import { spawnSync } from "node:child_process";
import { createHash, getHashes } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";

const BLOCK_SIZE = 512;
const EXACT_VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
const SHA1 = /^[a-f0-9]{40}$/;
const SHA256 = /^[a-f0-9]{64}$/;

export const REPOSITORY_ROOT = resolve(fileURLToPath(new URL("../", import.meta.url)));
export const VENDOR_DIRECTORY = join(REPOSITORY_ROOT, "vendor", "igv");
export const MANIFEST_PATH = join(VENDOR_DIRECTORY, "manifest.json");
export const BUNDLE_PATH = join(VENDOR_DIRECTORY, "igv.min.js");
export const LICENSE_PATH = join(VENDOR_DIRECTORY, "LICENSE");

const BUNDLE_RELATIVE_PATH = "vendor/igv/igv.min.js";
const LICENSE_RELATIVE_PATH = "vendor/igv/LICENSE";
const BUNDLE_NPM_PATH = "package/dist/igv.min.js";
const LICENSE_NPM_PATH = "package/LICENSE";
const PACKAGE_JSON_NPM_PATH = "package/package.json";

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function asObject(value, description) {
  assert(value !== null && typeof value === "object" && !Array.isArray(value), `${description} must be an object`);
  return value;
}

function asString(value, description) {
  assert(typeof value === "string" && value.length > 0, `${description} must be a non-empty string`);
  return value;
}

function asNullableString(value, description) {
  assert(value === null || typeof value === "string", `${description} must be a string or null`);
  return value;
}

function asNullablePositiveInteger(value, description) {
  assert(value === null || (Number.isSafeInteger(value) && value >= 0), `${description} must be a non-negative integer or null`);
  return value;
}

export function assertExactVersion(version, description = "Version") {
  assert(EXACT_VERSION.test(version), `${description} must be an exact SemVer version, not a tag or range: ${version}`);
  return version;
}

function validateArtifact(artifact, expectedPath, expectedNpmPath, description) {
  const value = asObject(artifact, description);
  assert(value.path === expectedPath, `${description}.path must be ${expectedPath}`);
  assert(value.npm_path === expectedNpmPath, `${description}.npm_path must be ${expectedNpmPath}`);
  const hash = asNullableString(value.sha256, `${description}.sha256`);
  if (hash !== null) assert(SHA256.test(hash), `${description}.sha256 must be a lowercase SHA-256 digest`);
  const bytes = asNullablePositiveInteger(value.bytes, `${description}.bytes`);
  assert((hash === null) === (bytes === null), `${description}.sha256 and ${description}.bytes must either both be set or both be null`);
  return value;
}

/** Validate the stable on-disk contract before touching any vendor artifact. */
export function validateManifest(manifest) {
  const value = asObject(manifest, "manifest");
  assert(value.schema_version === 1, "Unsupported IGV vendor manifest schema_version");

  const packageInfo = asObject(value.package, "manifest.package");
  assert(packageInfo.name === "igv", "manifest.package.name must be igv");
  assertExactVersion(asString(packageInfo.version, "manifest.package.version"), "manifest.package.version");
  assert(packageInfo.registry === "https://registry.npmjs.org/", "manifest.package.registry must be the npm registry HTTPS URL");

  const integrity = asNullableString(packageInfo.tarball_integrity, "manifest.package.tarball_integrity");
  const shasum = asNullableString(packageInfo.tarball_sha1, "manifest.package.tarball_sha1");
  assert((integrity === null) === (shasum === null), "manifest package integrity fields must either both be set or both be null");
  if (integrity !== null) assert(/^sha(?:256|384|512)-[A-Za-z0-9+/=]+$/.test(integrity), "manifest.package.tarball_integrity must be a supported SRI hash");
  if (shasum !== null) assert(SHA1.test(shasum), "manifest.package.tarball_sha1 must be a lowercase SHA-1 digest");

  const artifacts = asObject(value.artifacts, "manifest.artifacts");
  const bundle = validateArtifact(artifacts.bundle, BUNDLE_RELATIVE_PATH, BUNDLE_NPM_PATH, "manifest.artifacts.bundle");
  const license = validateArtifact(artifacts.license, LICENSE_RELATIVE_PATH, LICENSE_NPM_PATH, "manifest.artifacts.license");
  return { packageInfo, bundle, license };
}

export function readManifest() {
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(MANIFEST_PATH, "utf8"));
  } catch (error) {
    throw new Error(`Could not read ${relativeToRoot(MANIFEST_PATH)}: ${error.message}`);
  }
  validateManifest(manifest);
  return manifest;
}

export function sha256(contents) {
  return createHash("sha256").update(contents).digest("hex");
}

function sha1(contents) {
  return createHash("sha1").update(contents).digest("hex");
}

function describeNpmFailure(result) {
  const stdout = result.stdout ? result.stdout.trim() : "";
  const stderr = result.stderr ? result.stderr.trim() : "";
  return [stderr, stdout].filter(Boolean).join("\n");
}

function npmCommand() {
  return process.platform === "win32" ? "npm.cmd" : "npm";
}

function verifySri(contents, integrity) {
  for (const token of integrity.trim().split(/\s+/)) {
    const match = /^(sha(?:256|384|512))-([A-Za-z0-9+/=]+)$/.exec(token);
    if (!match) continue;
    const algorithm = match[1];
    if (!getHashes().includes(algorithm)) continue;
    const actual = createHash(algorithm).update(contents).digest("base64");
    if (actual === match[2]) return;
  }
  throw new Error("npm pack returned a tarball whose SRI integrity hash does not match its metadata");
}

/**
 * Fetch exactly one npm package.  The temporary cache prevents an update from
 * changing a developer's global npm cache or lockfiles.
 */
export function packExactNpmPackage(packageInfo) {
  assertExactVersion(packageInfo.version, "Package version");
  const temporaryDirectory = mkdirTemporaryDirectory("d4-plot-igv-pack-");
  try {
    const cacheDirectory = join(temporaryDirectory, "npm-cache");
    const result = spawnSync(
      npmCommand(),
      [
        "pack",
        "--ignore-scripts",
        "--json",
        "--cache",
        cacheDirectory,
        "--registry",
        packageInfo.registry,
        `${packageInfo.name}@${packageInfo.version}`,
      ],
      {
        cwd: temporaryDirectory,
        encoding: "utf8",
        maxBuffer: 64 * 1024 * 1024,
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    if (result.error) throw new Error(`Could not start npm: ${result.error.message}`);
    if (result.status !== 0) {
      const detail = describeNpmFailure(result);
      throw new Error(`npm pack failed for ${packageInfo.name}@${packageInfo.version}${detail ? `:\n${detail}` : ""}`);
    }

    let packed;
    try {
      packed = JSON.parse(result.stdout);
    } catch (error) {
      throw new Error(`npm pack did not return JSON metadata: ${error.message}`);
    }
    assert(Array.isArray(packed) && packed.length === 1, "npm pack must return exactly one package record");
    const metadata = packed[0];
    assert(metadata && metadata.name === packageInfo.name, "npm pack returned an unexpected package name");
    assert(metadata.version === packageInfo.version, "npm pack returned an unexpected package version");
    assert(metadata.id === `${packageInfo.name}@${packageInfo.version}`, "npm pack returned an unexpected package identity");
    assert(typeof metadata.filename === "string" && basename(metadata.filename) === metadata.filename, "npm pack returned an unsafe tarball filename");
    assert(typeof metadata.integrity === "string" && metadata.integrity.length > 0, "npm pack did not return a tarball integrity hash");
    assert(typeof metadata.shasum === "string" && SHA1.test(metadata.shasum), "npm pack did not return a valid tarball SHA-1 hash");

    const tarballPath = join(temporaryDirectory, metadata.filename);
    assert(existsSync(tarballPath) && lstatSync(tarballPath).isFile(), "npm pack did not create the announced tarball");
    const tarball = readFileSync(tarballPath);
    assert(sha1(tarball) === metadata.shasum, "npm pack tarball SHA-1 does not match its metadata");
    verifySri(tarball, metadata.integrity);
    return { metadata, tarball };
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

function mkdirTemporaryDirectory(prefix) {
  return mkdtempSync(join(tmpdir(), prefix));
}

function isZeroBlock(block) {
  for (const byte of block) if (byte !== 0) return false;
  return true;
}

function tarString(field) {
  const terminator = field.indexOf(0);
  return field.subarray(0, terminator === -1 ? field.length : terminator).toString("utf8");
}

function tarNumber(field, description) {
  const text = field.toString("ascii").replaceAll("\0", "").trim();
  if (text.length === 0) return 0;
  assert(/^[0-7]+$/.test(text), `Invalid tar ${description}`);
  const value = Number.parseInt(text, 8);
  assert(Number.isSafeInteger(value), `Tar ${description} is too large`);
  return value;
}

function verifyTarChecksum(header) {
  const expected = tarNumber(header.subarray(148, 156), "header checksum");
  let actual = 0;
  for (let index = 0; index < BLOCK_SIZE; index += 1) {
    actual += index >= 148 && index < 156 ? 32 : header[index];
  }
  assert(actual === expected, "Invalid tar header checksum");
}

/** Extract only named regular files from an npm tarball, without filesystem extraction. */
export function extractTarFiles(tarball, wantedPaths) {
  let tar;
  try {
    tar = gunzipSync(tarball);
  } catch (error) {
    throw new Error(`Could not decompress npm tarball: ${error.message}`);
  }

  const wanted = new Set(wantedPaths);
  const extracted = new Map();
  let offset = 0;
  while (offset < tar.length) {
    assert(offset + BLOCK_SIZE <= tar.length, "Truncated tar header");
    const header = tar.subarray(offset, offset + BLOCK_SIZE);
    if (isZeroBlock(header)) break;
    verifyTarChecksum(header);

    const prefix = tarString(header.subarray(345, 500));
    const name = tarString(header.subarray(0, 100));
    const path = prefix ? `${prefix}/${name}` : name;
    const size = tarNumber(header.subarray(124, 136), `size for ${path || "unnamed entry"}`);
    const dataStart = offset + BLOCK_SIZE;
    const dataEnd = dataStart + size;
    assert(dataEnd <= tar.length, `Truncated tar contents for ${path || "unnamed entry"}`);

    if (wanted.has(path)) {
      const type = header[156];
      assert(type === 0 || type === 48, `Expected ${path} to be a regular file in the npm tarball`);
      assert(!extracted.has(path), `npm tarball contains duplicate ${path} entries`);
      extracted.set(path, Buffer.from(tar.subarray(dataStart, dataEnd)));
    }

    const padding = (BLOCK_SIZE - (size % BLOCK_SIZE)) % BLOCK_SIZE;
    offset = dataEnd + padding;
    assert(offset <= tar.length, `Truncated tar padding for ${path || "unnamed entry"}`);
  }

  for (const path of wanted) assert(extracted.has(path), `npm tarball is missing required file ${path}`);
  return extracted;
}

function validatePackageJson(contents, expectedPackage) {
  let packageJson;
  try {
    packageJson = JSON.parse(contents.toString("utf8"));
  } catch (error) {
    throw new Error(`Could not parse package/package.json from npm tarball: ${error.message}`);
  }
  assert(packageJson.name === expectedPackage.name, "npm tarball package.json has an unexpected package name");
  assert(packageJson.version === expectedPackage.version, "npm tarball package.json has an unexpected package version");
  assert(packageJson.license === "MIT", "npm tarball package.json does not declare the expected MIT license");
}

export function unpackIgvArtifacts(tarball, expectedPackage) {
  const entries = extractTarFiles(tarball, [BUNDLE_NPM_PATH, LICENSE_NPM_PATH, PACKAGE_JSON_NPM_PATH]);
  validatePackageJson(entries.get(PACKAGE_JSON_NPM_PATH), expectedPackage);
  const bundle = entries.get(BUNDLE_NPM_PATH);
  const license = entries.get(LICENSE_NPM_PATH);
  assert(bundle.length > 0, "IGV.js bundle is empty");
  assert(license.length > 0, "IGV.js license is empty");
  return { bundle, license };
}

export function assertJavaScriptSyntax(path) {
  const result = spawnSync(process.execPath, ["--check", path], {
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.error) throw new Error(`Could not run Node.js syntax verification: ${result.error.message}`);
  if (result.status !== 0) {
    const detail = [result.stderr, result.stdout].filter(Boolean).join("\n").trim();
    throw new Error(`JavaScript syntax verification failed for ${relativeToRoot(path)}${detail ? `:\n${detail}` : ""}`);
  }
}

function verifyArtifact(path, artifact, description) {
  if (artifact.sha256 === null || artifact.bytes === null) {
    throw new Error(`${description} is not vendored yet. Run: node scripts/update-igv.mjs`);
  }
  if (!existsSync(path)) throw new Error(`Missing ${relativeToRoot(path)}. Run: node scripts/update-igv.mjs`);
  const file = lstatSync(path);
  assert(file.isFile() && !file.isSymbolicLink(), `${relativeToRoot(path)} must be a regular file`);
  const contents = readFileSync(path);
  assert(contents.length === artifact.bytes, `${relativeToRoot(path)} has an unexpected byte length`);
  assert(sha256(contents) === artifact.sha256, `${relativeToRoot(path)} does not match its manifest SHA-256`);
  return contents;
}

/** Verify the file hashes, bundle syntax, and source-provenance metadata. */
export function verifyVendoredIgv(manifest = readManifest()) {
  const { packageInfo, bundle, license } = validateManifest(manifest);
  const bundleContents = verifyArtifact(BUNDLE_PATH, bundle, "IGV.js bundle");
  verifyArtifact(LICENSE_PATH, license, "IGV.js license");
  assert(packageInfo.tarball_integrity !== null && packageInfo.tarball_sha1 !== null, "IGV.js npm provenance is missing. Run: node scripts/update-igv.mjs");
  assertJavaScriptSyntax(BUNDLE_PATH);
  return { version: packageInfo.version, bytes: bundleContents.length };
}

function temporarySibling(destination) {
  return join(
    dirname(destination),
    `.${basename(destination)}.${process.pid}.${createHash("sha256").update(`${Date.now()}-${Math.random()}`).digest("hex").slice(0, 12)}.tmp`,
  );
}

/** Write a file atomically within its destination directory. */
export function writeFileAtomically(destination, contents) {
  mkdirSync(dirname(destination), { recursive: true });
  const temporary = temporarySibling(destination);
  try {
    writeFileSync(temporary, contents, { mode: 0o644, flag: "wx" });
    renameSync(temporary, destination);
  } finally {
    rmSync(temporary, { force: true });
  }
}

export function writeManifestAtomically(manifest) {
  validateManifest(manifest);
  writeFileAtomically(MANIFEST_PATH, `${JSON.stringify(manifest, null, 2)}\n`);
}

export function makeUpdatedManifest(previousManifest, version, metadata, bundle, license) {
  const { packageInfo } = validateManifest(previousManifest);
  assertExactVersion(version, "Requested version");
  assert(metadata.name === packageInfo.name && metadata.version === version, "npm metadata does not match the requested IGV.js package");
  return {
    schema_version: 1,
    package: {
      name: packageInfo.name,
      version,
      registry: packageInfo.registry,
      tarball_integrity: metadata.integrity,
      tarball_sha1: metadata.shasum,
    },
    artifacts: {
      bundle: {
        path: BUNDLE_RELATIVE_PATH,
        npm_path: BUNDLE_NPM_PATH,
        sha256: sha256(bundle),
        bytes: bundle.length,
      },
      license: {
        path: LICENSE_RELATIVE_PATH,
        npm_path: LICENSE_NPM_PATH,
        sha256: sha256(license),
        bytes: license.length,
      },
    },
  };
}

export function relativeToRoot(path) {
  return relative(REPOSITORY_ROOT, path).replaceAll("\\", "/");
}
