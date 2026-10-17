require "./spec_helper"
require "file_utils"
require "xml"
require "../src/d4_plot/svg_export"

describe D4Plot::SvgExport do
  it "does not silently overwrite a file after adding the SVG extension" do
    File.tempfile("d4-plot-image", ".svg") do |file|
      file.close
      D4Plot::SvgExport.destination(file.path).should eq(file.path)
      chosen_path = file.path[0, file.path.size - 4]
      expect_raises(Exception, D4Plot.t("app.image_exists", name: File.basename(file.path))) do
        D4Plot::SvgExport.destination(chosen_path)
      end
      File.read(file.path).should be_empty
    end
  end

  it "saves the full plot, annotations, and XML-safe labels from a snapshot" do
    File.tempfile("d4-plot", ".svg") do |file|
      file.close
      region = D4Plot::Region.new("chr&1", 1_u32, 20_u32)
      first = D4Plot::TrackLayer.new(D4Plot::TrackSource.new("/tmp/sample2.d4", "A < B", {"chr&1" => 20_u32}, 1.0))
      second = D4Plot::TrackLayer.new(D4Plot::TrackSource.new("/tmp/sample10.d4", "C & D", {"chr&1" => 20_u32}, 1.0))
      first_view = D4Plot::SampledView.new(region, [{5_u32, 2.0}, {15_u32, 4.0}])
      first.view = first_view
      second.view = D4Plot::SampledView.new(region, [{5_u32, 6.0}, {15_u32, 8.0}])
      feature = D4Plot::AnnotationFeature.new("chr&1", 2_u32, 9_u32, "gene", "G<&>", "+")
      annotation_track = D4Plot::AnnotationTrack.features([feature])
      export = D4Plot::SvgExport.new(file.path, [] of String, region, [first, second], annotation_track,
        D4Plot::PlotSettings.new, 20_u32, 800, 220.0, false, first.source.key)

      first_view.points[0] = {5_u32, 99.0}
      export.write
      contents = File.read(file.path)
      document = XML.parse(contents)
      root = document.root || raise "SVG root is missing"
      root["width"].should eq("800")
      root["height"].should eq(D4Plot::StackGeometry.new(800.0, 220.0, 2).height(120.0).to_s)
      contents.should contain("sample2.d4 / A &lt; B")
      contents.should contain("sample10.d4 / C &amp; D")
      contents.should contain("G&lt;&amp;&gt;")
      contents.should contain("chr&amp;1")
      contents.should contain("plot-112")
      contents.should contain("plot-332")
      contents.should contain("L82.000 180.741")
    end
  end

  it "keeps SVG geometry finite for extreme but finite scaled signals" do
    File.tempfile("d4-plot-extreme", ".svg") do |file|
      file.close
      region = D4Plot::Region.new("chr", 1_u32, 2_u32)
      layer = D4Plot::TrackLayer.new(D4Plot::TrackSource.new("/tmp/extreme.d4", "signal", {"chr" => 2_u32}, 1.0))
      view = D4Plot::SampledView.new(region, [{1_u32, -1.0e308}, {2_u32, 1.0e308}])
      layer.view = view
      D4Plot::SvgExport.new(file.path, [] of String, region, [layer], nil,
        D4Plot::PlotSettings.new, 2_u32, 800, 220.0, false, nil).write

      contents = File.read(file.path).downcase
      contents.should_not contain("nan")
      contents.should_not contain("inf")
      view.mean.finite?.should be_true
    end
  end

  it "refuses to overwrite an input file through a hard link" do
    File.tempfile("d4-plot-svg-source") do |file|
      file.puts("keep source")
      file.close
      destination = "#{file.path}.svg"
      begin
        File.link(file.path, destination)
        region = D4Plot::Region.new("chr1", 1_u32, 10_u32)
        export = D4Plot::SvgExport.new(destination, [file.path], region, [] of D4Plot::TrackLayer,
          nil, D4Plot::PlotSettings.new, 10_u32, 800, 220.0, false, nil)
        expect_raises(Exception, D4Plot.t("app.export_conflict")) { export.write }
        File.read(file.path).should eq("keep source\n")
      ensure
        File.delete(destination) if File.exists?(destination)
      end
    end
  end

  it "writes a snapshot after a source file has been removed" do
    File.tempfile("d4-plot-svg") do |file|
      destination = file.path
      file.close
      source = File.tempname("d4-plot-removed-source")
      begin
        File.write(source, "removed source")
        File.delete(source)
        region = D4Plot::Region.new("chr1", 1_u32, 10_u32)

        D4Plot::SvgExport.new(destination, [source], region, [] of D4Plot::TrackLayer,
          nil, D4Plot::PlotSettings.new, 10_u32, 800, 220.0, false, nil).write
        File.read(destination).should contain("<svg")
      ensure
        File.delete?(source)
      end
    end
  end

  it "publishes through a same-directory temporary file without leaving it behind" do
    directory = File.tempname("d4-plot-svg-atomic")
    Dir.mkdir(directory)
    begin
      destination = File.join(directory, "plot.svg")
      region = D4Plot::Region.new("chr1", 1_u32, 10_u32)
      export = D4Plot::SvgExport.new(destination, [] of String, region, [] of D4Plot::TrackLayer,
        nil, D4Plot::PlotSettings.new, 10_u32, 800, 220.0, false, nil)

      export.write

      Dir.children(directory).should eq(["plot.svg"])
      File.read(destination).should contain("<svg")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "removes its temporary file when publication fails" do
    directory = File.tempname("d4-plot-svg-atomic-failure")
    Dir.mkdir(directory)
    begin
      destination = File.join(directory, "occupied")
      Dir.mkdir(destination)
      region = D4Plot::Region.new("chr1", 1_u32, 10_u32)
      export = D4Plot::SvgExport.new(destination, [] of String, region, [] of D4Plot::TrackLayer,
        nil, D4Plot::PlotSettings.new, 10_u32, 800, 220.0, false, nil)

      expect_raises(File::Error) { export.write }
      Dir.children(directory).should eq(["occupied"])
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
