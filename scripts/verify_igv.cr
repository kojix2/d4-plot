#!/usr/bin/env crystal

# The release build only needs to establish that the checked-in IGV.js files
# are the exact artifacts recorded in the manifest.  Keep this verifier in
# Crystal's standard library so normal builds do not need Node.js or npm.
require "digest/sha256"
require "json"

ROOT             = File.expand_path("..", __DIR__)
VENDOR_DIRECTORY = File.join(ROOT, "vendor", "igv")
MANIFEST_PATH    = File.join(VENDOR_DIRECTORY, "manifest.json")

EXACT_VERSION = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/
SHA1          = /\A[a-f0-9]{40}\z/
SHA256        = /\A[a-f0-9]{64}\z/
SRI           = /\Asha(?:256|384|512)-[A-Za-z0-9+\/=]+\z/

def fail(message : String) : NoReturn
  raise message
end

def object(value : JSON::Any, description : String) : Hash(String, JSON::Any)
  value.as_h? || fail("#{description} must be an object")
end

def field(object : Hash(String, JSON::Any), name : String, description : String) : JSON::Any
  object[name]? || fail("#{description}.#{name} is missing")
end

def string(value : JSON::Any, description : String) : String
  value.as_s?.try { |text| text.empty? ? nil : text } || fail("#{description} must be a non-empty string")
end

def nullable_string(value : JSON::Any, description : String) : String?
  return if value.raw.nil?
  value.as_s? || fail("#{description} must be a string or null")
end

def nullable_non_negative_integer(value : JSON::Any, description : String) : Int32?
  return if value.raw.nil?
  integer = value.as_i? || fail("#{description} must be a non-negative integer or null")
  integer >= 0 || fail("#{description} must be a non-negative integer or null")
  integer
end

def verify_artifact(
  artifact : JSON::Any,
  description : String,
  expected_path : String,
  expected_npm_path : String,
) : Int32
  value = object(artifact, description)
  string(field(value, "path", description), description + ".path") == expected_path || fail("#{description}.path must be #{expected_path}")
  string(field(value, "npm_path", description), description + ".npm_path") == expected_npm_path || fail("#{description}.npm_path must be #{expected_npm_path}")

  expected_hash = nullable_string(field(value, "sha256", description), description + ".sha256")
  expected_hash.nil? || SHA256.matches?(expected_hash) || fail("#{description}.sha256 must be a lowercase SHA-256 digest")
  expected_bytes = nullable_non_negative_integer(field(value, "bytes", description), description + ".bytes")
  expected_hash.nil? == expected_bytes.nil? || fail("#{description}.sha256 and #{description}.bytes must either both be set or both be null")
  expected_hash && expected_bytes || fail("#{description} is not vendored yet. Run: node scripts/update-igv.mjs")

  path = File.join(ROOT, expected_path)
  File.file?(path) && !File.symlink?(path) || fail("#{expected_path} must be a regular file")
  File.size(path) == expected_bytes || fail("#{expected_path} has an unexpected byte length")
  Digest::SHA256.hexdigest(File.read(path)) == expected_hash || fail("#{expected_path} does not match its manifest SHA-256")
  expected_bytes
end

begin
  ARGV.empty? || fail("Usage: crystal run scripts/verify_igv.cr")
  manifest = object(JSON.parse(File.read(MANIFEST_PATH)), "manifest")
  field(manifest, "schema_version", "manifest").as_i? == 1 || fail("Unsupported IGV vendor manifest schema_version")

  package_info = object(field(manifest, "package", "manifest"), "manifest.package")
  string(field(package_info, "name", "manifest.package"), "manifest.package.name") == "igv" || fail("manifest.package.name must be igv")
  version = string(field(package_info, "version", "manifest.package"), "manifest.package.version")
  EXACT_VERSION.matches?(version) || fail("manifest.package.version must be an exact SemVer version, not a tag or range: #{version}")
  string(field(package_info, "registry", "manifest.package"), "manifest.package.registry") == "https://registry.npmjs.org/" || fail("manifest.package.registry must be the npm registry HTTPS URL")

  integrity = nullable_string(field(package_info, "tarball_integrity", "manifest.package"), "manifest.package.tarball_integrity")
  tarball_sha1 = nullable_string(field(package_info, "tarball_sha1", "manifest.package"), "manifest.package.tarball_sha1")
  integrity.nil? == tarball_sha1.nil? || fail("manifest package integrity fields must either both be set or both be null")
  integrity.nil? || SRI.matches?(integrity) || fail("manifest.package.tarball_integrity must be a supported SRI hash")
  tarball_sha1.nil? || SHA1.matches?(tarball_sha1) || fail("manifest.package.tarball_sha1 must be a lowercase SHA-1 digest")
  integrity && tarball_sha1 || fail("IGV.js npm provenance is missing. Run: node scripts/update-igv.mjs")

  artifacts = object(field(manifest, "artifacts", "manifest"), "manifest.artifacts")
  bundle_bytes = verify_artifact(field(artifacts, "bundle", "manifest.artifacts"), "manifest.artifacts.bundle", "vendor/igv/igv.min.js", "package/dist/igv.min.js")
  verify_artifact(field(artifacts, "license", "manifest.artifacts"), "manifest.artifacts.license", "vendor/igv/LICENSE", "package/LICENSE")
  puts "Verified IGV.js #{version} (#{bundle_bytes} bytes)."
rescue error
  STDERR.puts "IGV.js verification failed: #{error.message}"
  exit 1
end
