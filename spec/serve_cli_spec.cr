require "./spec_helper"
require "../src/d4_plot/serve_cli"

private def serve_arguments(*arguments : String) : Array(String)
  arguments.to_a
end

describe D4Plot::ServeCLI do
  it "parses a standalone server invocation without loading a reference" do
    configuration = D4Plot::ServeCLI.parse(serve_arguments("--port", "0", "--region", "chr1:2-9", "--open", "sample.d4"))

    configuration.files.should eq(["sample.d4"])
    configuration.port.should eq(0)
    configuration.region.should eq("chr1:2-9")
    configuration.reference_mode.auto?.should be_true
    configuration.open_browser?.should be_true
  end

  it "keeps preset, FASTA, JSON, and contigs-only reference modes distinct" do
    D4Plot::ServeCLI.parse(serve_arguments("--genome", "hg38", "sample.d4")).reference_mode.preset?.should be_true

    fasta = D4Plot::ServeCLI.parse(serve_arguments("--reference", "reference.fa", "--reference-index", "reference.fa.fai", "sample.d4"))
    fasta.reference_mode.file?.should be_true
    fasta.reference_index.should eq("reference.fa.fai")

    D4Plot::ServeCLI.parse(serve_arguments("--reference", "reference.genome.json", "sample.d4")).reference_mode.file?.should be_true
    D4Plot::ServeCLI.parse(serve_arguments("--contigs-only", "sample.d4")).reference_mode.contigs_only?.should be_true
  end

  it "allows a reference-only genome browser without D4 files" do
    preset = D4Plot::ServeCLI.parse(serve_arguments("--genome", "hg38", "--open"))
    preset.files.should be_empty
    preset.reference_mode.preset?.should be_true

    local = D4Plot::ServeCLI.parse(serve_arguments("--reference", "reference.fa"))
    local.files.should be_empty
    local.reference_mode.file?.should be_true
  end

  it "rejects mutually exclusive and incomplete reference options" do
    expect_raises(D4Plot::ServeCLI::UsageError, /cannot be used together/) do
      D4Plot::ServeCLI.parse(serve_arguments("--genome", "hg38", "--reference", "reference.fa", "sample.d4"))
    end
    expect_raises(D4Plot::ServeCLI::UsageError, /requires --reference/) do
      D4Plot::ServeCLI.parse(serve_arguments("--reference-index", "reference.fa.fai", "sample.d4"))
    end
    expect_raises(D4Plot::ServeCLI::UsageError, /provide a .d4 file/) do
      D4Plot::ServeCLI.parse([] of String)
    end
    expect_raises(D4Plot::ServeCLI::UsageError, /provide a .d4 file/) do
      D4Plot::ServeCLI.parse(serve_arguments("--contigs-only"))
    end
  end

  it "preserves diagnostics for conflicting reference modes and JSON indexes" do
    cases = [
      {serve_arguments("--contigs-only", "--genome", "hg38"), "--contigs-only cannot be combined"},
      {serve_arguments("--contigs-only", "--reference", "reference.fa"), "--contigs-only cannot be combined"},
      {serve_arguments("--reference", "reference.JSON", "--reference-index", "reference.fai"), "--reference-index cannot be used"},
      {serve_arguments("--genome", "hg38", "--reference", "reference.fa", "--contigs-only"), "--genome and --reference cannot be used together"},
    ]
    cases.each do |arguments, message|
      expect_raises(D4Plot::ServeCLI::UsageError, message) { D4Plot::ServeCLI.parse(arguments) }
    end
  end

  it "handles help before reference conflicts without modifying the caller's arguments" do
    arguments = serve_arguments("--help", "--genome", "hg38", "--reference", "missing.fa", "sample.d4")
    original = arguments.dup
    configuration = D4Plot::ServeCLI.parse(arguments)
    configuration.help?.should be_true
    configuration.files.should be_empty
    configuration.reference_mode.auto?.should be_true
    arguments.should eq(original)
  end
end
