require "./spec_helper"
require "../src/d4_plot/annotation"
require "./support/indexed_annotation"

describe D4Plot::AnnotationIndex do
  it "converts BED half-open intervals and keeps GFF/GTF coordinates inclusive" do
    bed = D4Plot::AnnotationIndex.parse_line("chr1\t0\t1\tone base\t0\t-").as(D4Plot::AnnotationFeature)
    {bed.start1, bed.end1, bed.strand}.should eq({1_u32, 1_u32, "-"})
    gtf = D4Plot::AnnotationIndex.parse_line("chr1\tref\texon\t1\t1\t.\t+\t.\tgene_name \"A\";").as(D4Plot::AnnotationFeature)
    {gtf.start1, gtf.end1, gtf.name}.should eq({1_u32, 1_u32, "A"})
    unknown_strand = D4Plot::AnnotationIndex.parse_line("chr1\tref\tgene\t1\t10\t.\t?\t.\tID=A").as(D4Plot::AnnotationFeature)
    unknown_strand.strand.should be_nil
    D4Plot::AnnotationIndex.parse_line("chr1\t1\t1").should be_nil
    D4Plot::AnnotationIndex.parse_line("chr1\tref\tgene\t0\t10\t.\t+\t.\tID=A").should be_nil
  end

  it "reports chromosome mismatches and includes boundary overlaps" do
    feature = D4Plot::AnnotationFeature.new("chr1", 10_u32, 20_u32, "gene", "A", "+")
    index = D4Plot::AnnotationIndex.new("test.gff", [feature])
    index.overlapping(D4Plot::Region.new("chr1", 20_u32, 20_u32), 10).size.should eq(1)
    index.overlapping(D4Plot::Region.new("chr1", 21_u32, 21_u32), 10).should be_empty
    index.track_for(D4Plot::Region.new("1", 1_u32, 20_u32), 100_u32, 10).notice.as(String).should contain("names must match")
    index.track_for(D4Plot::Region.new("chr1", 21_u32, 30_u32), 100_u32, 10).notice.should eq("No overlapping annotations in this region")
  end

  it "stops parsing an unindexed file when a newer view supersedes it" do
    path = File.tempname("d4-annotation-cancel", ".bed")
    begin
      File.write(path, "chr1\t0\t1\n" * 2_000)
      checks = 0
      expect_raises(D4Plot::AnnotationCancelled) do
        D4Plot::AnnotationIndex.load(path, -> { checks += 1; checks >= 2 })
      end
      D4Plot::AnnotationIndex.load(path).size.should eq(2_000)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "allows comments after exactly the in-memory feature limit" do
    path = File.tempname("d4-annotation-limit", ".bed")
    begin
      File.write(path, "chr1\t0\t1\n" * D4Plot::AnnotationIndex::MAX_IN_MEMORY_FEATURES + "# trailing comment\n")
      D4Plot::AnnotationIndex.load(path).size.should eq(D4Plot::AnnotationIndex::MAX_IN_MEMORY_FEATURES)
      File.open(path, "a", &.puts("chr1\t1\t2"))
      expect_raises(Exception, /in-memory limit/) { D4Plot::AnnotationIndex.load(path) }
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "bounds an individual unindexed record before loading it into memory" do
    path = File.tempname("d4-annotation-long-line", ".bed")
    begin
      File.write(path, "chr1\t0\t1\t" + "A" * (D4Plot::AnnotationIndex::MAX_IN_MEMORY_LINE_BYTES + 1))
      expect_raises(Exception, /in-memory limit/) { D4Plot::AnnotationIndex.load(path) }
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "reads an unindexed BGZF annotation with a BGZF suffix" do
    path = File.tempname("d4-annotation-bgz", ".bed.bgz")
    begin
      HTS::Bgzf.open(path, "wz", &.write("chr1\t0\t1\tfeature\n"))
      index = D4Plot::AnnotationIndex.load(path)
      index.indexed?.should be_false
      index.overlapping(D4Plot::Region.new("chr1", 1_u32, 1_u32), 10).map(&.name).should eq(["feature"])
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end

describe "Indexed annotations" do
  it "recognizes standard BGZF filename suffixes" do
    contents = "chr1\t0\t1\tfeature\n"
    {".bgz", ".bgzf", ".bgzip"}.each do |suffix|
      AnnotationFixtures.with_indexed(contents, ".bed", :bed, 0, suffix) do |path|
        index = D4Plot::AnnotationIndex.load(path)
        index.indexed?.should be_true
        index.overlapping(D4Plot::Region.new("chr1", 1_u32, 1_u32), 10).map(&.name).should eq(["feature"])
      end
    end
  end

  it "reads indexed BED records, preserves boundaries, and recovers after the feature limit" do
    contents = "chr1\t0\t10\tA\t0\t+\nchr1\t0\t20\tB\t0\t-\nchr1\t1\t30\tC\t0\t+\n"
    AnnotationFixtures.with_indexed(contents) do |path|
      region = D4Plot::Region.new("chr1", 1_u32, 30_u32)
      plain = D4Plot::AnnotationIndex.new("plain", contents.lines.compact_map { |line| D4Plot::AnnotationIndex.parse_line(line) })
      indexed = D4Plot::AnnotationIndex.load(path)
      indexed.chromosome_names.should eq(["chr1"])
      indexed.overlapping(region, 10).should eq(plain.overlapping(region, 10))
      indexed.track_for(region, 100_u32, 1).notice.should eq("Too many annotations (>1); zoom in")
      indexed.overlapping(D4Plot::Region.new("chr1", 10_u32, 10_u32), 10).map(&.name).should eq(["A", "B", "C"])
      indexed.overlapping(D4Plot::Region.new("chr1", 11_u32, 11_u32), 10).map(&.name).should eq(["B", "C"])
    end
  end

  {0, 14}.each do |min_shift|
    it "reads GTF through #{min_shift == 0 ? "TBI" : "CSI"} with inclusive coordinates" do
      contents = "chr1\tref\tgene\t1\t10\t.\t+\t.\tgene_name \"A\";\n" +
                 "chr1\tref\texon\t10\t20\t.\t-\t.\tgene_name \"B\";\n" +
                 "chr1\tref\tCDS\t21\t24\t.\t+\t.\tgene_name \"ignored\";\n"
      AnnotationFixtures.with_indexed(contents, ".gtf", :gff, min_shift) do |path|
        File.exists?("#{path}.#{min_shift == 0 ? "tbi" : "csi"}").should be_true
        index = D4Plot::AnnotationIndex.load(path)
        index.overlapping(D4Plot::Region.new("chr1", 10_u32, 10_u32), 10).map(&.name).should eq(["A", "B"])
        index.overlapping(D4Plot::Region.new("chr1", 11_u32, 20_u32), 10).map(&.name).should eq(["B"])
        index.overlapping(D4Plot::Region.new("chr1", 21_u32, 24_u32), 10).should be_empty
        index.track_for(D4Plot::Region.new("missing", 1_u32, 10_u32), 100_u32, 10).notice.as(String).should contain("names must match")
      end
    end
  end
end
