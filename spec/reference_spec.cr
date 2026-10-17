require "./spec_helper"
require "../src/d4_plot/reference"

private def with_reference_fixture(&)
  directory = File.tempname("d4-plot-reference")
  Dir.mkdir(directory)
  begin
    yield directory
  ensure
    if Dir.exists?(directory)
      Dir.each_child(directory) { |child| File.delete(File.join(directory, child)) }
      Dir.delete(directory)
    end
  end
end

private def write_small_fasta(directory : String, name : String = "reference.fa") : String
  fasta = File.join(directory, name)
  # First bases are at offsets 6 and 17 respectively.
  File.write(fasta, ">chr1\nACGT\n>chrM\nAAA\n")
  File.write("#{fasta}.fai", "chr1\t4\t6\t4\t5\nchrM\t3\t17\t3\t4\n")
  fasta
end

describe D4Plot::ReferenceSpec do
  it "resolves a local FASTA with its implicit FAI without creating files" do
    with_reference_fixture do |directory|
      fasta = write_small_fasta(directory)
      resolved = D4Plot::ReferenceSpec.fasta(fasta).resolve
      dictionary = resolved.dictionary || raise "FASTA reference has no dictionary"

      resolved.kind.should eq(D4Plot::ReferenceKind::Fasta)
      dictionary["chr1"].should eq(4_i64)
      dictionary["chrM"].should eq(3_i64)
      resolved.resources.map(&.id).should eq(["fasta", "fai"])
      resolved.resources.map(&.path).should contain(File.realpath(fasta))

      config = JSON.parse(resolved.igv_browser_config_json({
        "fasta" => "/reference/fasta",
        "fai"   => "/reference/fai",
      })).as_h
      reference = config["reference"].as_h
      reference["fastaURL"].as_s.should eq("/reference/fasta")
      reference["indexURL"].as_s.should eq("/reference/fai")
      expect_raises(D4Plot::ReferenceValidationError, /No browser URL/) do
        resolved.igv_browser_config_json({"fasta" => "/reference/fasta"})
      end
    end
  end

  it "requires a structurally valid FAI and rejects coordinates above UInt32" do
    with_reference_fixture do |directory|
      fasta = write_small_fasta(directory)
      File.delete("#{fasta}.fai")
      expect_raises(D4Plot::ReferenceValidationError, /FAI/) do
        D4Plot::ReferenceSpec.fasta(fasta).resolve
      end

      File.write("#{fasta}.fai", "chr1\t4294967296\t6\t4\t5\n")
      expect_raises(D4Plot::ReferenceValidationError, /maximum/) do
        D4Plot::ReferenceSpec.fasta(fasta).resolve
      end

      File.write("#{fasta}.fai", "chr1\t4\t6\t4\t3\n")
      expect_raises(D4Plot::ReferenceValidationError, /bytes per line/) do
        D4Plot::ReferenceSpec.fasta(fasta).resolve
      end

      File.write("#{fasta}.fai", "x" * (D4Plot::FaiIndex::MAX_LINE_BYTES + 2))
      expect_raises(D4Plot::ReferenceValidationError, /too long/) do
        D4Plot::ReferenceSpec.fasta(fasta).resolve
      end
    end
  end

  it "validates FAI header identity and fixed line geometry with bounded reads" do
    with_reference_fixture do |directory|
      fasta = File.join(directory, "geometry.fa")

      # A description after the contig name, a short final row, and a
      # single-row contig are all valid LF FASTA/FAI combinations.
      File.write(fasta, ">chr description\nAAAA\nAA\n>single\nT\n")
      File.write("#{fasta}.fai", "chr\t6\t17\t4\t5\nsingle\t1\t33\t1\t2\n")
      D4Plot::ReferenceSpec.fasta(fasta).resolve.dictionary.try(&.["chr"]).should eq(6_i64)

      # CRLF has a two-byte line separator in the FAI.
      File.write(fasta, ">crlf\r\nAAAA\r\nAA\r\n")
      File.write("#{fasta}.fai", "crlf\t6\t7\t4\t6\n")
      D4Plot::ReferenceSpec.fasta(fasta).resolve.dictionary.try(&.["crlf"]).should eq(6_i64)

      # The old first/last-byte check accepted this malformed width because
      # its calculated last byte happened to be a nucleotide.
      File.write(fasta, ">chr\nAAAA\nAAAA\n")
      File.write("#{fasta}.fai", "chr\t8\t5\t4\t4\n")
      expect_raises(D4Plot::ReferenceValidationError, /line geometry/) do
        D4Plot::ReferenceSpec.fasta(fasta).resolve
      end

      # Offsets must begin after the named header, not inside a header or at a
      # valid sequence row belonging to a different contig.
      File.write(fasta, ">chr\nAAAA\n")
      File.write("#{fasta}.fai", "chr\t3\t1\t3\t4\n")
      expect_raises(D4Plot::ReferenceValidationError, /FASTA header/) do
        D4Plot::ReferenceSpec.fasta(fasta).resolve
      end

      File.write(fasta, ">first\nAAAA\n>chr\nTTTT\n")
      File.write("#{fasta}.fai", "chr\t4\t7\t4\t5\n")
      expect_raises(D4Plot::ReferenceValidationError, /does not match its FASTA header/) do
        D4Plot::ReferenceSpec.fasta(fasta).resolve
      end
    end
  end

  it "reads a constrained IGV JSON with local relative resources and aliases" do
    with_reference_fixture do |directory|
      fasta = write_small_fasta(directory, "genome.fa")
      aliases = File.join(directory, "aliases.tsv")
      File.write(aliases, "# refseq\tucsc\nNC_000001.1\tchr1\nNC_012920.1\tchrM\n")
      sizes = File.join(directory, "chrom.sizes")
      File.write(sizes, "chr1\t4\nchrM\t3\n")
      json = File.join(directory, "genome.json")
      File.write(json, %({"id":"test","name":"Test assembly","format":"fasta","fastaURL":"#{File.basename(fasta)}","indexURL":"#{File.basename(fasta)}.fai","aliasURL":"aliases.tsv","chromSizesURL":"chrom.sizes"}))

      resolved = D4Plot::ReferenceSpec.igv_json(json).resolve
      resolved.aliases.canonical_for("NC_000001.1").should eq("chr1")
      resolved.resources.map(&.id).should eq(["fasta", "fai", "aliases", "chrom-sizes"])

      descriptor = resolved.resources.find! { |resource| resource.id == "fasta" }.to_json
      descriptor.should_not contain(File.realpath(fasta))
      config = resolved.igv_browser_config_json({
        "fasta"       => "/reference/fasta",
        "fai"         => "/reference/fai",
        "aliases"     => "/reference/aliases",
        "chrom-sizes" => "/reference/chrom-sizes",
      })
      config.should_not contain(File.realpath(fasta))
      config.should contain("/reference/aliases")

      File.write(json, %({"fastaURL":"genome.fa","unsupported":"value"}))
      expect_raises(D4Plot::ReferenceValidationError, /Unsupported IGV genome JSON key/) do
        D4Plot::ReferenceSpec.igv_json(json).resolve
      end
    end
  end

  it "distinguishes exact, explicit, conservative, partial, and incompatible dictionaries" do
    reference = D4Plot::ContigDictionary.new([
      D4Plot::Contig.new("chr1", 10_i64),
      D4Plot::Contig.new("chrM", 5_i64),
    ])
    resolved = D4Plot::ReferenceSpec.contigs_only(reference).resolve

    conservative = resolved.compatibility_with({"1" => 10_u32, "MT" => 5_u32})
    conservative.status.should eq(D4Plot::CompatibilityStatus::Compatible)
    conservative.track_name_for("chr1").should eq("1")
    conservative.matches.map(&.kind).should contain(D4Plot::ContigMatchKind::ConservativeAlias)

    partial = resolved.compatibility_with({"chr1" => 10_u32})
    partial.status.should eq(D4Plot::CompatibilityStatus::Partial)
    partial.missing_reference_contigs.should eq(["chrM"])

    ambiguous = resolved.compatibility_with({"chr1" => 10_u32, "MT" => 5_u32, "M" => 5_u32})
    ambiguous.status.should eq(D4Plot::CompatibilityStatus::Incompatible)
    ambiguous.ambiguous_contigs.first.reference_name.should eq("chrM")

    mismatch = resolved.compatibility_with({"chr1" => 9_u32, "chrM" => 5_u32})
    mismatch.status.should eq(D4Plot::CompatibilityStatus::Incompatible)
    mismatch.length_mismatches.first.reference_name.should eq("chr1")

    explicit = D4Plot::ReferenceSpec.fasta("unused.fa", aliases: {"scaffold-one" => "chr1"})
    # Explicit aliases are validated only once a real reference dictionary is
    # available; the standalone alias type documents the mapping direction.
    explicit.aliases.canonical_for("scaffold-one").should eq("chr1")
  end

  it "marks presets without a supplied dictionary as unverified and gives contigs-only a generated resource" do
    preset = D4Plot::ReferenceSpec.preset("hg38").resolve
    preset.dictionary.should be_nil
    preset.compatibility_with({"chr1" => 10_u32}).status.should eq(D4Plot::CompatibilityStatus::Unverified)
    preset_config = JSON.parse(preset.igv_browser_config_json).as_h
    preset_config["loadDefaultGenomes"].as_bool.should be_false
    preset_config["genome"].as_s.should eq("hg38")
    preset_config["genomeList"].as_a.first["twoBitURL"].as_s.should contain("hg38.2bit")
    preset.browser_connect_origins.should contain("https://hgdownload.soe.ucsc.edu")

    contigs = D4Plot::ReferenceSpec.contigs_only({"chr1" => 10_u32}).resolve
    resource = contigs.resources.first
    resource.generated?.should be_true
    resource.content.should eq("chr1\t10\n")
    contigs.browser_connect_origins.should be_empty
    contigs_config = contigs.igv_browser_config_json({"chrom-sizes" => "/reference/chrom-sizes"})
    contigs_config.should contain("chromsizes")
    contigs_config.should contain("\"loadDefaultGenomes\":false")
  end

  it "requires each curated preset resource origin to be allowed by its CSP origin list" do
    expect_raises(D4Plot::ReferenceValidationError, /not allowed/) do
      D4Plot::PresetRegistry::BrowserDefinition.new(
        "https://allowed.example/reference.2bit",
        "https://different.example/reference.chrom.sizes",
        ["https://allowed.example"])
    end
    expect_raises(D4Plot::ReferenceValidationError, /not allowed/) do
      D4Plot::PresetRegistry::BrowserDefinition.new(
        "https://allowed.example/reference.2bit",
        "https://allowed.example/reference.chrom.sizes",
        ["https://allowed.example"],
        gene_track_url: "https://different.example/genes.bb")
    end
  end

  it "loads assembly-matched gene annotations only for public presets" do
    expected = {
      "hg38" => "gencodeV50.bb",
      "hg19" => "gencodeV49lift37.bb",
      "hs1"  => "ncbiRefSeq.bb",
      "mm39" => "gencodeVM39.bb",
    }
    expected.each do |id, filename|
      config = D4Plot::ReferenceSpec.preset(id).resolve.igv_browser_config
      track = config["genomeList"].as_a.first["tracks"].as_a.first
      track["type"].as_s.should eq("annotation")
      track["format"].as_s.should eq("bigbed")
      track["url"].as_s.should end_with(filename)
    end
    contigs = D4Plot::ReferenceSpec.contigs_only({"chr1" => 10_u32}).resolve
    config = contigs.igv_browser_config({"chrom-sizes" => "/reference/chrom-sizes"})
    config["reference"].as_h.has_key?("tracks").should be_false
  end
end
