require "./spec_helper"
require "file_utils"
require "../src/d4_plot/bigwig_export"

describe D4Plot::BigWigExport do
  it "writes every original interval with its D4 denominator applied" do
    directory = File.tempname("d4-bigwig-export")
    Dir.mkdir(directory)
    begin
      source_path = File.join(directory, "source.d4")
      destination = File.join(directory, "signal.bw")
      D4.create(source_path, chromosomes: [D4::Chromosome.new("chr2", 4), D4::Chromosome.new("chr1", 3)], denominator: 2.0) do |writer|
        writer.write_values("chr2", 0, [0, -4, -4, 6])
        writer.write_values("chr1", 0, [2, 2, 8])
      end
      source = D4Plot::TrackSource.load(source_path).first

      D4Plot::BigWigExport.new(destination, [source_path], source).write

      BigWig.open(destination) do |reader|
        reader.chromosomes.keys.should eq(["chr1", "chr2"])
        reader.intervals("chr1").should eq([
          BigWig::Interval.new(0, 2, 1.0),
          BigWig::Interval.new(2, 3, 4.0),
        ])
        reader.intervals("chr2").should eq([
          BigWig::Interval.new(0, 1, 0.0),
          BigWig::Interval.new(1, 3, -2.0),
          BigWig::Interval.new(3, 4, 3.0),
        ])
      end
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "rejects an input path and preserves an existing output if writing fails" do
    directory = File.tempname("d4-bigwig-export")
    Dir.mkdir(directory)
    begin
      source_path = File.join(directory, "source.d4")
      D4.create(source_path, chromosomes: [D4::Chromosome.new("chr", 2)], denominator: 1e-40) do |writer|
        writer.write_values("chr", 0, [1, 2])
      end
      source = D4Plot::TrackSource.load(source_path).first
      expect_raises(Exception, D4Plot.t("app.export_conflict")) do
        D4Plot::BigWigExport.new(source_path, [source_path], source).write
      end

      destination = File.join(directory, "signal.bw")
      File.write(destination, "previous BigWig")
      expect_raises(ArgumentError, "D4 signal exceeds BigWig's Float32 range") do
        D4Plot::BigWigExport.new(destination, [source_path], source).write
      end
      File.read(destination).should eq("previous BigWig")
      Dir.children(directory).sort.should eq(["signal.bw", "source.d4"])
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "adds a BigWig extension when the chosen path has none" do
    D4Plot::BigWigExport.destination("track").should eq("track.bw")
    D4Plot::BigWigExport.destination("track.bigwig").should eq("track.bigwig")
  end
end
