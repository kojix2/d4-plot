require "./spec_helper"
require "../src/d4_plot/conversion_worker"
require "../src/d4_plot/conversion_draft"

private def conversion_fixture(dir, indexed = true)
  path = File.join(dir, "input.bam")
  header = HTS::Bam::Header.parse("@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:chr1\tLN:20\n@SQ\tSN:empty\tLN:5\n")
  HTS::Bam.open(path, "wb") do |bam|
    bam.write_header(header)
    # Mate overlap at [4,6), a deletion at [10,12), and a filtered duplicate.
    [{"pair", 99_u16, 2_i64, 60_u8, "4M", "AAAA", 0, 4_i64, 6_i64},
     {"pair", 147_u16, 4_i64, 60_u8, "4M", "AAAA", 0, 2_i64, -6_i64},
     {"gap", 0_u16, 8_i64, 10_u8, "2M2D2M", "AAAA", -1, 0_i64, 0_i64},
     {"duplicate", 1024_u16, 15_i64, 60_u8, "2M", "AA", -1, 0_i64, 0_i64}].each do |name, flag, pos, mapq, cigar, seq, mtid, mpos, tlen|
      bam.write(HTS::Bam::Record.new(header, name, flag, "chr1", pos, mapq, cigar,
        seq, Array(UInt8).new(seq.size, 30_u8), mtid, mpos, tlen))
    end
  end
  HTS::Bam.build_index(path, verbose: false) if indexed
  path
end

private def in_conversion_dir(&)
  dir = File.tempname("d4-plot-conversion-spec")
  Dir.mkdir(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def converted_values(request)
  D4Plot::D4Converter.new.run(request)
  D4.open(request.output, &.values("chr1"))
end

describe D4Plot::D4Converter do
  it "writes indexed, gap-aware and mate-corrected coverage, including empty chromosomes" do
    in_conversion_dir do |dir|
      input = conversion_fixture(dir)
      output = File.join(dir, "standard.d4")
      events = [] of D4Plot::ConversionProgress
      request = D4Plot::ConversionRequest.new(input, output)
      D4Plot::D4Converter.new.run(request, progress: ->(event : D4Plot::ConversionProgress) { events << event; nil }).should eq(output)
      D4.open(output) do |file|
        file.values("chr1").should eq([0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0])
        file.values("empty").should eq([0, 0, 0, 0, 0])
        file.default_track.has_index?(D4::IndexKind::SecondaryFrames).should be_true
        file.default_track.has_index?(D4::IndexKind::Sum).should be_true
      end
      events.last.records.should eq(4)
      events.map(&.stage).should contain("Building D4 index")
      indexed = events.select { |event| event.stage == "Building D4 index" && !event.chromosome.empty? }
      indexed.map { |event| {event.chromosome, event.current, event.total} }.should eq([
        {"chr1", 1, 2}, {"empty", 2, 2},
        {"chr1", 1, 2}, {"empty", 2, 2},
      ])
      events.select(&.chromosome.empty?).each(&.total.should(eq(0)))
      Dir.children(dir).sort.should eq(["input.bam", "input.bam.bai", "standard.d4"])
    end
  end

  it "uses mopdepth's fast and fragment modes and MAPQ/flag/template filters" do
    in_conversion_dir do |dir|
      request = D4Plot::ConversionRequest.new(conversion_fixture(dir), File.join(dir, "fast.d4"), mode: D4Plot::CoverageMode::Fast)
      converted_values(request).should eq([0, 0, 1, 1, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0])
      fragments = request.copy_with(output: File.join(dir, "fragments.d4"), mode: D4Plot::CoverageMode::Fragment)
      converted_values(fragments).should eq([0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
      filtered = request.copy_with(output: File.join(dir, "filtered.d4"), mode: D4Plot::CoverageMode::Standard, mapq: 20, exclude_flags: 0_u16, include_flags: 1024_u16)
      converted_values(filtered).should eq([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0])
      limited = fragments.copy_with(output: File.join(dir, "limited.d4"), max_fragment: 5)
      converted_values(limited).should eq(Array(Int32).new(20, 0))
      groups = request.copy_with(output: File.join(dir, "groups.d4"), read_groups: ["missing"])
      converted_values(groups).should eq(Array(Int32).new(20, 0))
    end
  end

  it "rejects missing indexes and existing destinations without changing files" do
    in_conversion_dir do |dir|
      request = D4Plot::ConversionRequest.new(conversion_fixture(dir, false), File.join(dir, "result.d4"))
      expect_raises(D4Plot::ConversionError, /index is required/) { D4Plot::D4Converter.new.run(request) }
      File.exists?(request.output).should be_false
      File.write(request.output, "keep me")
      expect_raises(D4Plot::ConversionError, /already exists/) { D4Plot::D4Converter.new.run(request) }
      File.read(request.output).should eq("keep me")
      Dir.children(dir).any?(&.includes?(".d4-plot-")).should be_false
    end
  end

  it "cleans up cancellation before, during, and after finalization without publishing" do
    in_conversion_dir do |dir|
      input = conversion_fixture(dir)
      ["Checking input", "Reading alignments", "Writing coverage", "Finalizing D4", "Building D4 index", "Verifying D4"].each_with_index do |stage, i|
        control = D4Plot::ConversionControl.new
        request = D4Plot::ConversionRequest.new(input, File.join(dir, "cancel#{i}.d4"))
        callback = ->(event : D4Plot::ConversionProgress) { control.cancel if event.stage == stage; nil }
        expect_raises(D4Plot::ConversionCancelled) { D4Plot::D4Converter.new.run(request, control, callback) }
        File.exists?(request.output).should be_false
        Dir.children(dir).any?(&.includes?(".d4-plot-")).should be_false
      end
    end
  end

  it "does not overwrite a destination created while the job is running" do
    in_conversion_dir do |dir|
      request = D4Plot::ConversionRequest.new(conversion_fixture(dir), File.join(dir, "race.d4"))
      callback = ->(event : D4Plot::ConversionProgress) { File.write(request.output, "other writer") if event.stage == "Verifying D4"; nil }
      expect_raises(File::Error) { D4Plot::D4Converter.new.run(request, progress: callback) }
      File.read(request.output).should eq("other writer")
      Dir.children(dir).any?(&.includes?(".d4-plot-")).should be_false
    end
  end

  it "observes cancellation inside the indexed BAM reader" do
    in_conversion_dir do |dir|
      input = File.join(dir, "many.bam")
      header = HTS::Bam::Header.parse("@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:chr1\tLN:20\n")
      HTS::Bam.open(input, "wb") do |bam|
        bam.write_header(header)
        record = HTS::Bam::Record.new(header, "read", 0_u16, "chr1", 2_i64, 60_u8, "3M", "AAA", [30_u8] * 3, -1, 0_i64, 0_i64)
        20_000.times { bam.write(record) }
      end
      HTS::Bam.build_index(input, verbose: false)
      output = File.join(dir, "cancelled.d4")
      control = D4Plot::ConversionControl.new
      count = 0_i64
      callback = ->(event : D4Plot::ConversionProgress) {
        count = event.records
        control.cancel if count >= 8192
        nil
      }
      expect_raises(D4Plot::ConversionCancelled) do
        D4Plot::D4Converter.new.run(D4Plot::ConversionRequest.new(input, output), control, callback)
      end
      count.should eq(8192)
      File.exists?(output).should be_false
      Dir.children(dir).sort.should eq(["many.bam", "many.bam.bai"])
    end
  end

  it "creates the same coverage from CRAM with an explicit indexed reference" do
    in_conversion_dir do |dir|
      input = conversion_fixture(dir)
      reference = File.join(dir, "reference.fa")
      File.write(reference, ">chr1\n#{"A" * 20}\n>empty\nAAAAA\n")
      HTS::Faidx.new(reference).close
      cram = File.join(dir, "input.cram")
      HTS::Bam.open(input) do |reader|
        HTS::Bam.open(cram, "wc", fai: reference) do |writer|
          writer.write_header(reader.header)
          reader.each { |record| writer.write(record) }
        end
      end
      HTS::Bam.build_index(cram, verbose: false)
      request = D4Plot::ConversionRequest.new(cram, File.join(dir, "cram.d4"))
      expect_raises(D4Plot::ConversionError, /reference FASTA/) { D4Plot::D4Converter.new.run(request) }
      values = converted_values(request.copy_with(reference: reference))
      values.should eq(converted_values(request.copy_with(input: input, output: File.join(dir, "bam.d4"))))
    end
  end
end

describe D4Plot::ConversionWorker do
  it "publishes a terminal snapshot and can reset and retry after failure" do
    in_conversion_dir do |dir|
      worker = D4Plot::ConversionWorker.new
      worker.start(D4Plot::ConversionRequest.new(File.join(dir, "missing.bam"), File.join(dir, "result.d4")))
      worker.wait
      worker.snapshot.state.failed?.should be_true
      worker.snapshot.field.should eq("Input")
      worker.reset
      worker.snapshot.state.idle?.should be_true
      worker.start(D4Plot::ConversionRequest.new(conversion_fixture(dir), File.join(dir, "result.d4")))
      worker.wait
      worker.snapshot.state.succeeded?.should be_true
      worker.cancel
      worker.snapshot.state.succeeded?.should be_true
      output = worker.snapshot.output
      fail "conversion output is missing" unless output
      File.file?(output).should be_true
    end
  end
end

describe D4Plot::ConversionDraft do
  it "updates suggested destinations but preserves a user's chosen filename" do
    draft = D4Plot::ConversionDraft.new
    input_dir = File.join(Dir.tempdir, "data")
    draft.choose_input(File.join(input_dir, "one.bam"))
    draft.output.should eq(File.join(input_dir, "one.d4"))
    draft.choose_input(File.join(input_dir, "two.cram"))
    draft.output.should eq(File.join(input_dir, "two.d4"))
    draft.cram?.should be_true
    custom = File.join(Dir.tempdir, "results", "custom.d4")
    draft.output = custom
    draft.choose_input(File.join(input_dir, "three.bam"))
    draft.output.should eq(custom)
  end

  it "parses advanced options and reports hidden changes and invalid input" do
    draft = D4Plot::ConversionDraft.new
    draft.advanced_modified?.should be_false
    draft.mapq = 20
    draft.advanced_modified?.should be_true
    draft.mapq = 0
    draft.advanced_modified?.should be_false
    draft.exclude_flags = "0x704"
    draft.include_flags = "0x2"
    draft.read_groups = "tumor, normal, "
    draft.min_fragment = "100"
    draft.request.exclude_flags.should eq(1796_u16)
    draft.request.include_flags.should eq(2_u16)
    draft.request.read_groups.should eq(["tumor", "normal"])
    draft.request.min_fragment.should eq(100)
    draft.advanced_modified?.should be_true
    draft.include_flags = "65536"
    expect_raises(D4Plot::ConversionError) { draft.request }
  end
end
