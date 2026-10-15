require "./spec_helper"
require "../src/d4_plot/data_sampler"

describe D4Plot::DataSampler do
  it "samples the displayed bins from a Rust-generated D4 file" do
    path = File.join(__DIR__, "fixtures/rust-input-10nt.d4")
    D4.open(path) do |file|
      points = D4Plot::DataSampler.downsample(file, "chr", 0_u32, 10_u32, 4)
      points.should eq([{2_u32, 0.0}, {5_u32, 5.0 / 3}, {7_u32, 1.5}, {9_u32, 0.5}])
      D4Plot::DataSampler.downsample(file, "chr", 3_u32, 7_u32, 256).should eq(
        [{4_u32, 1.0}, {5_u32, 2.0}, {6_u32, 2.0}, {7_u32, 2.0}])
      [{0_u32, 10_u32, 3}, {2_u32, 9_u32, 4}, {3_u32, 10_u32, 2}].each do |start0, end0, count|
        expected = file.sample(D4::Region.new("chr", start0, end0), bins: count).map do |bin|
          {((bin.start + bin.stop - 1) // 2 + 1).to_u32, bin.sum.to_f64 / bin.length}
        end
        D4Plot::DataSampler.downsample(file, "chr", start0, end0, count).should eq(expected)
      end
    end
  end
end

describe D4Plot::DataSampler do
  it "applies the D4 denominator without hiding negative signal" do
    path = File.tempname("d4-plot-scaled", ".d4")
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 4)], denominator: 2.0) do |writer|
        writer.write_values("chr", 0, [2_i32, 4_i32, -6_i32, 0_i32])
      end
      D4.open(path) do |file|
        D4Plot::DataSampler.downsample(file, "chr", 0_u32, 4_u32, 2).should eq([{1_u32, 1.5}, {3_u32, -1.5}])
        expect_raises(ArgumentError) { D4Plot::DataSampler.downsample(file, "chr", 0_u32, 5_u32) }
        expect_raises(D4Plot::SamplingCancelled) do
          D4Plot::DataSampler.downsample(file, "chr", 0_u32, 4_u32, 2, false, -> { true })
        end
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "samples a selected track from a multi-track file" do
    D4.open(File.join(__DIR__, "fixtures/rust-multitrack.d4")) do |file|
      file.track_names.each do |name|
        track = file.track(name)
        chromosome = track.chromosomes.first
        region = D4::Region.new(chromosome.name, 0_i64, chromosome.size)
        expected = track.sample(region, bins: 4).map do |bin|
          {((bin.start + bin.stop - 1) // 2 + 1).to_u32, bin.sum.to_f64 / bin.length / track.metadata.denominator}
        end
        D4Plot::DataSampler.downsample(track, chromosome.name, 0_u32, chromosome.size.to_u32, 4).should eq(expected)
      end
    end
  end

  it "samples explicit Int64 half-open bins and preserves denominator semantics" do
    path = File.tempname("d4-plot-explicit-bins", ".d4")
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 6)], denominator: 2.0) do |writer|
        writer.write_values("chr", 0, [2_i32, 4_i32, -6_i32, 0_i32, 8_i32, 10_i32])
      end
      D4.open(path) do |file|
        bins = [D4Plot::BinRange.new(0_i64, 2_i64), D4Plot::BinRange.new(2_i64, 5_i64), D4Plot::BinRange.new(5_i64, 6_i64)]
        sampled = D4Plot::DataSampler.sample_bins(file.default_track, "chr", bins)
        sampled.should eq([
          D4Plot::SampledBin.new(0_i64, 2_i64, 1.5),
          D4Plot::SampledBin.new(2_i64, 5_i64, 1.0 / 3),
          D4Plot::SampledBin.new(5_i64, 6_i64, 5.0),
        ])
        expect_raises(ArgumentError, /contiguous/) do
          D4Plot::DataSampler.sample_bins(file.default_track, "chr", [D4Plot::BinRange.new(0_i64, 2_i64), D4Plot::BinRange.new(3_i64, 4_i64)])
        end
        expect_raises(D4Plot::SamplingBudgetExceeded, /would scan 6 bases/) do
          D4Plot::DataSampler.sample_bins(file.default_track, "chr", [D4Plot::BinRange.new(0_i64, 6_i64)],
            max_streaming_bases: 5_i64)
        end
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "uses a sum index even when the chromosome ends in a short bin" do
    path = File.tempname("d4-plot-indexed-tail", ".d4")
    begin
      size = 100_001_i64
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", size)],
        dictionary: D4::Dictionary.new([0_i32, 1_i32]),
        options: D4::WriteOptions.new(indexes: [D4::IndexKind::Sum])) do |writer|
        writer.write_values("chr", 0, [1_i32, 1_i32])
        writer.write_values("chr", 65_536, [1_i32])
      end
      D4.open(path) do |file|
        track = file.default_track
        track.has_index?(D4::IndexKind::Sum).should be_true
        bins = [D4Plot::BinRange.new(0_i64, 65_536_i64), D4Plot::BinRange.new(65_536_i64, size)]
        sampled = D4Plot::DataSampler.sample_bins(track, "chr", bins, max_streaming_bases: 1_i64)
        sampled.map(&.value).should eq([2.0 / 65_536, 1.0 / (size - 65_536)])
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "shows bounded sampled means when exact unindexed aggregation exceeds the display budget" do
    path = File.tempname("d4-plot-display-sampling", ".d4")
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 10)],
        dictionary: D4::Dictionary.new([0_i32, 1_i32, 2_i32, 3_i32])) do |writer|
        writer.write_values("chr", 0, [0_i32, 0_i32, 0_i32, 1_i32, 2_i32,
                                       2_i32, 2_i32, 1_i32, 1_i32, 0_i32])
      end
      D4.open(path) do |file|
        bins = [D4Plot::BinRange.new(0_i64, 10_i64)]
        exact = D4Plot::DataSampler.display_bins(file.default_track, "chr", bins,
          max_streaming_bases: 10_i64, max_sample_bases: 4_i64)
        exact.exact.should be_true
        exact.bins.first.value.should eq(0.9)

        sampled = D4Plot::DataSampler.display_bins(file.default_track, "chr", bins,
          max_streaming_bases: 5_i64, max_sample_bases: 4_i64)
        sampled.exact.should be_false
        sampled.bins.first.value.should eq(1.0)
        sampled.bins.first.start0.should eq(0_i64)
        sampled.bins.first.end0.should eq(10_i64)
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
