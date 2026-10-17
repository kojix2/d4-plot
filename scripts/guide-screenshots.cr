#!/usr/bin/env crystal

# Capture publication screenshots from the native macOS windows.
# Usage: crystal run scripts/guide-screenshots.cr -- OUTPUT_DIRECTORY [en|ja]
# OUTPUT_DIRECTORY must not exist. All genomic data are synthetic.
require "../src/d4_plot/app"
require "file_utils"

{% if flag?(:darwin) %}
  @[Link("objc")]
  lib GuideScreenshotObjC
    fun sel_registerName(name : UInt8*) : Void*
    fun window_number = objc_msgSend(receiver : Void*, selector : Void*) : Int64
  end

  lib GuideScreenshotCommand
    fun system(command : UInt8*) : Int32
  end
{% end %}

module GuideScreenshots
  CHROMOSOME_SIZE = 10_000
  REGION          = "chr1:1,001-9,000"

  def self.capture(window : UIng::Window, path : String) : Nil
    {% if flag?(:darwin) %}
      id = GuideScreenshotObjC.window_number(window.handle, GuideScreenshotObjC.sel_registerName("windowNumber"))
      raise "No native window ID for #{path}" unless id > 0
      command = Process.quote({"/usr/sbin/screencapture", "-x", "-o", "-l", id.to_s, path})
      raise "Window screenshot failed: #{path}" unless GuideScreenshotCommand.system(command) == 0
      raise "Window screenshot is empty: #{path}" unless File.exists?(path) && File.size(path) > 5_000
    {% else %}
      raise "Guide screenshots require macOS"
    {% end %}
  end

  private def self.peak(position : Int32, center : Int32, radius : Int32, height : Int32) : Int32
    distance = (position - center).abs
    distance >= radius ? 0 : height * (radius - distance) // radius
  end

  private def self.coverage(position : Int32, sample : Int32) : Int32
    baseline = 3 + (position // 41) % 3
    if sample == 0
      baseline + peak(position, 2_800, 620, 32) + peak(position, 6_700, 900, 18)
    else
      baseline + peak(position, 3_050, 720, 19) + peak(position, 6_500, 760, 29)
    end
  end

  def self.make_fixtures(directory : String) : NamedTuple(tracks: Array(String), annotation: String, bam: String)
    tracks = ["sample-A", "sample-B"].map_with_index do |name, sample|
      path = File.join(directory, "#{name}.d4")
      values = Array.new(CHROMOSOME_SIZE) { |position| coverage(position, sample) }
      D4.create(path, chromosomes: [D4::Chromosome.new("chr1", CHROMOSOME_SIZE)]) do |writer|
        writer.write_values("chr1", 0, values)
      end
      path
    end

    annotation_path = File.join(directory, "demo-genes.bed")
    File.write(annotation_path, "chr1\t2300\t4600\tDemoGeneA\nchr1\t6000\t7800\tDemoGeneB\n")

    bam = File.join(directory, "demo-alignment.bam")
    header = HTS::Bam::Header.parse("@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:chr1\tLN:#{CHROMOSOME_SIZE}\n")
    HTS::Bam.open(bam, "wb") do |file|
      file.write_header(header)
      file.write(HTS::Bam::Record.new(header, "demo-read", 0_u16, "chr1", 2_750_i64, 60_u8, "10M",
        "A" * 10, [30_u8] * 10, -1, 0_i64, 0_i64))
    end
    HTS::Bam.build_index(bam, verbose: false)
    {tracks: tracks, annotation: annotation_path, bam: bam}
  end
end

class D4Plot::ConversionWindow
  def guide_set_files(input : String, output : String) : Nil
    @input.text = input
    @output.text = output
  end

  def guide_capture(path : String) : Nil
    GuideScreenshots.capture(@window, path)
  end

  def guide_hide : Nil
    @window.hide
  end
end

class D4Plot::App
  def guide_ready?(with_annotation : Bool) : Bool
    return false if @loading || @file_load_id || @completed_region.nil? || @layers.size != 2
    return false unless @layers.all? { |layer| !layer.view.nil? && layer.error.nil? }
    !with_annotation || !@annotation.nil?
  end

  def guide_show_annotation(path : String) : Nil
    @shared_y.checked = true
    @pending_annotation_path = path
    refresh
  end

  def guide_narrow : Nil
    request_view(D4Plot::Region.new("chr1", 2_001_u32, 5_000_u32))
  end

  def guide_capture(path : String) : Nil
    GuideScreenshots.capture(@window, path)
  end

  def guide_open_conversion(input : String, output : String) : Nil
    open_conversion
    @conversion_window.not_nil!.guide_set_files(input, output)
  end

  def guide_capture_conversion(path : String) : Nil
    @conversion_window.not_nil!.guide_capture(path)
  end

  def guide_stop : Nil
    @conversion_window.try(&.guide_hide)
    shutdown
    @window.destroy
    UIng.quit
  end
end

output = ARGV[0]? || raise "Usage: guide-screenshots.cr OUTPUT_DIRECTORY [en|ja]"
locale = ARGV[1]? || "en"
raise "Use en or ja for screenshots" unless {"en", "ja"}.includes?(locale)
output = File.expand_path(output)
raise "Output directory already exists: #{output}" if File.exists?(output)

D4Plot::UIRuntime.prepare
fixtures = D4Plot::UIRuntime.load do
  Dir.mkdir(output)
  path = File.tempname("d4-plot-guide-fixtures")
  Dir.mkdir(path)
  {path, GuideScreenshots.make_fixtures(path)}
end
fixture_dir, data = fixtures
failure : Exception? = nil
begin
  D4Plot::Translations.setup(locale)
  UIng.init
  preferences = D4Plot::Preferences.new(File.join(fixture_dir, "settings.json"), locale)
  app = D4Plot::App.new(D4Plot::App.create_menu_bar, preferences)
  UIng.on_error { |error, _context| failure = error }
  step = 0
  started = Time.instant
  UIng.timer(400) do
    begin
      raise failure.not_nil! if failure
      raise "Guide screenshots timed out" if Time.instant - started > 45.seconds
      case step
      when 0
        if app.guide_ready?(false)
          app.guide_show_annotation(data[:annotation])
          step += 1
        end
      when 1
        if app.guide_ready?(true)
          app.guide_capture(File.join(output, "overview.png"))
          app.guide_narrow
          step += 1
        end
      when 2
        if app.guide_ready?(true)
          app.guide_capture(File.join(output, "inspect.png"))
          app.guide_open_conversion(data[:bam], File.join(fixture_dir, "new-coverage.d4"))
          step += 1
        end
      when 3
        app.guide_capture_conversion(File.join(output, "create-d4.png"))
        app.guide_stop
        step += 1
      end
      step > 3 ? 0 : 1
    rescue ex
      failure = ex
      app.guide_stop
      0
    end
  end
  app.run(data[:tracks], GuideScreenshots::REGION)
ensure
  FileUtils.rm_rf(fixture_dir)
end
failure.try { |error| raise error }
puts "Captured guide screenshots (#{locale}) in #{output}"
