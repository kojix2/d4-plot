require "./spec_helper"
require "file_utils"
require "../src/d4_plot/bedgraph_export"

describe D4Plot::BedgraphExport do
  it "exports the captured bins even after the displayed data changes" do
    File.tempfile("d4-export") do |file|
      file.close
      view = D4Plot::SampledView.new(D4Plot::Region.new("chr1", 1_u32, 10_u32), [{1_u32, 3.0}])
      export = D4Plot::BedgraphExport.new(file.path, [] of String, "input\n.d4", "track\r1", view)
      view.points[0] = {1_u32, 99.0}
      export.write
      contents = File.read(file.path)
      contents.should contain("# Source: input .d4; track: track 1\n")
      contents.should contain("chr1\t0\t10\t3")
      contents.should_not contain("99")
    end
  end

  it "refuses to overwrite a source through a hard link" do
    File.tempfile("d4-export-source") do |file|
      file.puts("keep source")
      file.close
      destination = "#{file.path}.alias"
      begin
        File.link(file.path, destination)
        view = D4Plot::SampledView.new(D4Plot::Region.new("chr1", 1_u32, 10_u32), [{1_u32, 3.0}])
        export = D4Plot::BedgraphExport.new(destination, [file.path], file.path, "", view)
        expect_raises(Exception, D4Plot.t("app.export_conflict")) { export.write }
        File.read(file.path).should eq("keep source\n")
      ensure
        File.delete(destination) if File.exists?(destination)
      end
    end
  end

  it "rejects chromosome names that cannot be represented as a bedGraph field" do
    File.tempfile("d4-export") do |file|
      file.print("keep destination")
      file.close

      ["chr1\nforged", "chr1\u0000forged"].each do |chromosome|
        view = D4Plot::SampledView.new(D4Plot::Region.new(chromosome, 1_u32, 10_u32), [{1_u32, 3.0}])
        expect_raises(ArgumentError, /bedGraph cannot represent/) do
          D4Plot::BedgraphExport.new(file.path, [] of String, "input.d4", "track", view)
        end
      end
      File.read(file.path).should eq("keep destination")
    end
  end

  it "exports when a formerly registered source has been removed" do
    File.tempfile("d4-export") do |file|
      destination = file.path
      file.close
      source = File.tempname("d4-export-removed-source")
      begin
        File.write(source, "removed source")
        File.delete(source)
        view = D4Plot::SampledView.new(D4Plot::Region.new("chr1", 1_u32, 10_u32), [{1_u32, 3.0}])

        D4Plot::BedgraphExport.new(destination, [source], source, "track", view).write
        File.read(destination).should contain("chr1\t0\t10\t3")
      ensure
        File.delete?(source)
      end
    end
  end

  it "publishes through a same-directory temporary file without leaving it behind" do
    directory = File.tempname("d4-export-atomic")
    Dir.mkdir(directory)
    begin
      destination = File.join(directory, "coverage.bedgraph")
      view = D4Plot::SampledView.new(D4Plot::Region.new("chr1", 1_u32, 10_u32), [{1_u32, 3.0}])

      D4Plot::BedgraphExport.new(destination, [] of String, "input.d4", "track", view).write

      Dir.children(directory).should eq(["coverage.bedgraph"])
      File.read(destination).should contain("chr1\t0\t10\t3")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "removes its temporary file when publication fails" do
    directory = File.tempname("d4-export-atomic-failure")
    Dir.mkdir(directory)
    begin
      destination = File.join(directory, "occupied")
      Dir.mkdir(destination)
      view = D4Plot::SampledView.new(D4Plot::Region.new("chr1", 1_u32, 10_u32), [{1_u32, 3.0}])
      export = D4Plot::BedgraphExport.new(destination, [] of String, "input.d4", "track", view)

      expect_raises(File::Error) { export.write }
      Dir.children(directory).should eq(["occupied"])
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
