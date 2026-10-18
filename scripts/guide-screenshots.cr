#!/usr/bin/env crystal

# Capture publication screenshots from the native macOS windows.
# Usage: crystal run scripts/guide-screenshots.cr -- OUTPUT_DIRECTORY [en|ja]
# OUTPUT_DIRECTORY must not exist. The displayed D4 is a repository test fixture.
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
  CHROMOSOME_SIZE = 20_000
  REGION          = "1:9,001-16,000"
  TRACK_FIXTURE   = File.expand_path("../spec/fixtures/rust-multitrack.d4", __DIR__)

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

  def self.make_fixtures(directory : String) : NamedTuple(tracks: Array(String), annotation: String, bam: String)
    sources = D4Plot::TrackSource.load(TRACK_FIXTURE)
    raise "Unexpected guide D4 fixture contents" unless sources.size == 2 && sources.all? { |source| source.chromosomes["1"]? == CHROMOSOME_SIZE }

    annotation_path = File.join(directory, "demo-genes.bed")
    File.write(annotation_path, "1\t9975\t10200\tDemoGeneA\n1\t13000\t14300\tDemoGeneB\n")

    bam = File.join(directory, "demo-alignment.bam")
    header = HTS::Bam::Header.parse("@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:1\tLN:#{CHROMOSOME_SIZE}\n")
    HTS::Bam.open(bam, "wb") do |file|
      file.write_header(header)
      file.write(HTS::Bam::Record.new(header, "demo-read", 0_u16, "1", 10_005_i64, 60_u8, "10M",
        "A" * 10, [30_u8] * 10, -1, 0_i64, 0_i64))
    end
    HTS::Bam.build_index(bam, verbose: false)
    {tracks: [TRACK_FIXTURE], annotation: annotation_path, bam: bam}
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
    @pending_annotation_path = path
    refresh
  end

  def guide_narrow : Nil
    request_view(D4Plot::Region.new("1", 9_951_u32, 10_250_u32))
  end

  def guide_capture(path : String) : Nil
    GuideScreenshots.capture(@window, path)
  end

  def guide_open_conversion(input : String, output : String) : Nil
    open_conversion
    window = @conversion_window || raise "Conversion window was not opened"
    window.guide_set_files(input, output)
  end

  def guide_capture_conversion(path : String) : Nil
    window = @conversion_window || raise "Conversion window was not opened"
    window.guide_capture(path)
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
    if error = failure
      raise error
    end
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
    step <= 3
  rescue ex
    failure = ex
    app.guide_stop
    false
  end
  app.run(data[:tracks], GuideScreenshots::REGION)
ensure
  FileUtils.rm_rf(fixture_dir)
end
failure.try { |error| raise error }
puts "Captured guide screenshots (#{locale}) in #{output}"
