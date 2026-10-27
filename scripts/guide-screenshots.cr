#!/usr/bin/env crystal

# Prepare a stable native window for window-screenshot-action on every OS.
# Usage: crystal run scripts/guide-screenshots.cr -- overview|inspect|create-d4 [en|ja]
# Compiled copies named guide-<scene>[.exe] also select the scene without arguments.
# The capture action owns window capture and process termination.
require "../src/d4_plot/app"
require "file_utils"

{% if flag?(:darwin) %}
  @[Link("objc")]
  lib GuideApplication
    fun objc_getClass(name : UInt8*) : Void*
    fun sel_registerName(name : UInt8*) : Void*
    fun shared_application = objc_msgSend(receiver : Void*, selector : Void*) : Void*
    fun class_getMethodImplementation(klass : Void*, selector : Void*) : Void*
  end
{% end %}

module GuideScreenshots
  CHROMOSOME_SIZE = 20_000
  REGION          = "1:9,001-16,000"
  TRACK_FIXTURE   = File.expand_path("../spec/fixtures/rust-multitrack.d4", __DIR__)

  def self.activate : Nil
    {% if flag?(:darwin) %}
      klass = GuideApplication.objc_getClass("NSApplication")
      application = GuideApplication.shared_application(klass,
        GuideApplication.sel_registerName("sharedApplication"))
      selector = GuideApplication.sel_registerName("activateIgnoringOtherApps:")
      implementation = GuideApplication.class_getMethodImplementation(klass, selector)
      activate = Proc(Pointer(Void), Pointer(Void), Bool, Nil).new(implementation, Pointer(Void).null)
      activate.call(application, selector, true)
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

  def guide_prepare_inspection(path : String) : Nil
    @pending_annotation_path = path
    request_view(D4Plot::Region.new("1", 9_951_u32, 10_250_u32))
  end

  def guide_show : Nil
    # Leave room for native decorations within the action's 1280x800 X11 screen.
    @window.set_content_size(1120, 760)
    @window.show
    @area.focus
    @area.queue_redraw_all
  end

  def guide_open_conversion(input : String, output : String) : Nil
    open_conversion
    window = @conversion_window || raise "Conversion window was not opened"
    window.guide_set_files(input, output)
  end

  def guide_stop : Nil
    @conversion_window.try(&.guide_hide)
    shutdown
    @window.destroy
    UIng.quit
  end
end

scene = ARGV[0]? || File.basename(PROGRAM_NAME, ".exe").sub(/\Aguide-/, "")
locale = ARGV[1]? || ENV["D4_PLOT_SCREENSHOT_LOCALE"]? || "en"
raise "Use overview, inspect, or create-d4 for the screenshot scene" unless {"overview", "inspect", "create-d4"}.includes?(scene)
raise "Use en or ja for screenshots" unless {"en", "ja"}.includes?(locale)

D4Plot::UIRuntime.prepare
# Windows GUI executables can start without stdout/stderr. Readiness is
# signaled by revealing the window, so this capture helper needs no console IO.
Log.setup(:none)
fixtures = D4Plot::UIRuntime.load do
  path = File.tempname("d4-plot-guide-fixtures")
  Dir.mkdir(path)
  {path, GuideScreenshots.make_fixtures(path)}
end
fixture_dir, data = fixtures
failure : Exception? = nil
begin
  Dir.cd(fixture_dir)
  D4Plot::Translations.setup(locale)
  UIng.init
  preferences = D4Plot::Preferences.new(File.join(fixture_dir, "settings.json"), locale)
  preferences.height_index = 0
  app = D4Plot::App.new(D4Plot::App.create_menu_bar, preferences)
  UIng.on_error { |error, _context| failure = error }
  inspecting = false
  started = Time.instant
  UIng.timer(100) do
    D4Plot::UIRuntime.check_thread!
    if error = failure
      raise error
    end
    raise "Guide screenshot preparation timed out" if Time.instant - started > 45.seconds
    next true unless app.guide_ready?(inspecting)
    if scene == "inspect" && !inspecting
      app.guide_prepare_inspection(data[:annotation])
      inspecting = true
      next true
    end
    # Reveal only the final target window, so the action cannot discover an
    # empty/loading main window or capture it instead of the conversion dialog.
    if scene == "create-d4"
      app.guide_open_conversion(File.basename(data[:bam]), "new-coverage.d4")
    else
      app.guide_show
    end
    GuideScreenshots.activate
    false
  rescue ex
    failure = ex
    app.guide_stop
    false
  end
  app.run(data[:tracks], GuideScreenshots::REGION, show_window: false)
ensure
  FileUtils.rm_rf(fixture_dir)
end
failure.try { |error| raise error }
