require "./spec_helper"
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
end
