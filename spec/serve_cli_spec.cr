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

  it "rejects mutually exclusive and incomplete reference options" do
    expect_raises(D4Plot::ServeCLI::UsageError, /cannot be used together/) do
      D4Plot::ServeCLI.parse(serve_arguments("--genome", "hg38", "--reference", "reference.fa", "sample.d4"))
    end
    expect_raises(D4Plot::ServeCLI::UsageError, /requires --reference/) do
      D4Plot::ServeCLI.parse(serve_arguments("--reference-index", "reference.fa.fai", "sample.d4"))
    end
    expect_raises(D4Plot::ServeCLI::UsageError, /at least one/) do
      D4Plot::ServeCLI.parse([] of String)
    end
  end
end
