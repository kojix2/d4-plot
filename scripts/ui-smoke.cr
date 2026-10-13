# Native UI regression harness. Run from the repository root:
#   crystal run scripts/ui-smoke.cr -- /path/to/new-screenshot-directory
# Screenshots are optional, macOS-only, and captured by this process's NSWindow
# ID. The desktop and other applications are never captured, even temporarily.
require "../src/d4_plot/app"

{% if flag?(:darwin) %}
  @[Link("objc")]
  lib SmokeObjC
    fun sel_registerName(name : UInt8*) : Void*
    fun window_number = objc_msgSend(receiver : Void*, selector : Void*) : Int64
  end

  lib SmokeCommand
    fun system(command : UInt8*) : Int32
  end
{% end %}

module UiSmoke
  def self.capture(window : UIng::Window, directory : String?, name : String)
    return unless directory
    {% if flag?(:darwin) %}
      id = SmokeObjC.window_number(window.handle, SmokeObjC.sel_registerName("windowNumber"))
      raise "No native window ID" unless id > 0
      # -l is a window-specific acquisition, not a desktop capture plus crop.
      # Do not yield a native AppKit callback to Crystal's migratable default
      # scheduler. The OS wait is short and restricted to this test harness.
      command = Process.quote({"/usr/sbin/screencapture", "-x", "-o", "-l", id.to_s, File.join(directory, "#{name}.png")})
      raise "Window screenshot failed" unless SmokeCommand.system(command) == 0
    {% else %}
      raise "Window screenshots are only configured on macOS; omit the output directory."
    {% end %}
  end

  def self.check(value, message)
    raise message unless value
  end
end

class D4Plot::ConversionWindow
  def smoke_capture(directory, name)
    UiSmoke.capture(@window, directory, name)
  end

  def smoke_configure(input, output)
    @input.text = input
    @output.text = output
    @draft.choose_input(input)
    sync_reference(true)
  end

  def smoke_advanced
    @draft.advanced_open = true
    @advanced.show
    @window.set_content_size(660, 700)
    @exclude.text = "0x704"
    update_advanced_label
  end

  def smoke_create
    create
  end

  def smoke_hide
    @window.hide
  end

  def smoke_add
    add_to_view
    UiSmoke.check(@added && !@add.enabled?, "Add to view did not update its completion state")
  end

  def smoke_preserved(input, output)
    UiSmoke.check(@input.text == input && @output.text == output, "Conversion draft was lost on reopen")
    UiSmoke.check(@draft.advanced_open?, "Advanced state was lost on reopen")
  end
end

class D4Plot::App
  def smoke_step(step, directory, fixtures)
    step <= 5 ? smoke_early_step(step, directory, fixtures) : smoke_late_step(step, directory, fixtures)
  end

  private def smoke_conversion_window
    @conversion_window || raise "Conversion window is not open"
  end

  private def smoke_early_step(step, directory, fixtures)
    case step
    when 0
      UiSmoke.check(@welcome.visible?, "Empty state is missing")
      UiSmoke.capture(@window, directory, "01-empty")
      open_conversion
    when 1
      smoke_conversion_window.smoke_capture(directory, "02-create-basic")
      smoke_conversion_window.smoke_configure(File.join(fixtures, "input.bam"), File.join(fixtures, "output.d4"))
      smoke_conversion_window.smoke_advanced
    when 2
      smoke_conversion_window.smoke_capture(directory, "03-create-advanced")
      smoke_conversion_window.smoke_hide
      open_conversion
      smoke_conversion_window.smoke_preserved(File.join(fixtures, "input.bam"), File.join(fixtures, "output.d4"))
      smoke_conversion_window.smoke_create
      smoke_conversion_window.smoke_hide
    when 3
      return false if @conversion_worker.snapshot.state.active?
      UiSmoke.check(@conversion_worker.snapshot.state.succeeded?, "Conversion failed: #{@conversion_worker.snapshot.error}")
      UiSmoke.check(@layers.empty?, "Completion unexpectedly changed the current view")
      open_conversion
      return true
    when 4
      smoke_conversion_window.smoke_capture(directory, "04-create-complete")
      smoke_conversion_window.smoke_add
      smoke_conversion_window.smoke_hide
    when 5
      return false if @loading
      UiSmoke.check(@layers.size == 1, "Add to view failed")
      @pending_annotation_path = File.join(fixtures, "genes.bed")
      refresh
    end
    true
  end

  private def smoke_late_step(step, directory, fixtures)
    step <= 8 ? smoke_view_step(step, directory, fixtures) : smoke_retry_step(step, directory, fixtures)
  end

  private def smoke_view_step(step, directory, fixtures)
    case step
    when 6
      return false if @loading
      UiSmoke.check(!@details_visible && !@details.visible?, "Annotations opened Show details")
      UiSmoke.check(@annotation_path == File.join(fixtures, "genes.bed"), "Annotation selection was not committed")
      UiSmoke.capture(@window, directory, "05-view-annotation")
      @pending_annotation_path = File.join(fixtures, "missing.bed")
      request_view(D4Plot::Region.new("chr1", 6_u32, 15_u32))
    when 7
      return false if @loading
      UiSmoke.check(@annotation_path == File.join(fixtures, "genes.bed"), "Failed replacement lost the annotation")
      UiSmoke.check(@annotation.try(&.features.first?.try(&.name)) == "B", "Fallback used stale coordinates")
      UiSmoke.check(!@details_visible, "Failed replacement opened Show details")
      UiSmoke.capture(@window, directory, "06-annotation-failure")
      @details_toggle.text = D4Plot.t("app.hide_details")
      @details_visible = true
      @details.show
      @window.set_content_size(850, 620)
      resize_canvas
    when 8
      UiSmoke.capture(@window, directory, "07-compact-details")
      open_conversion
      smoke_conversion_window.smoke_create # Create another (keep settings).
      smoke_conversion_window.smoke_configure(File.join(fixtures, "unindexed.bam"), File.join(fixtures, "retry.d4"))
      smoke_conversion_window.smoke_create
    end
    true
  end

  private def smoke_retry_step(step, directory, fixtures)
    case step
    when 9
      return false if @conversion_worker.snapshot.state.active?
      UiSmoke.check(@conversion_worker.snapshot.state.failed?, "Missing index did not report failure")
      UiSmoke.check(@layers.size == 1 && @annotation_path == File.join(fixtures, "genes.bed"), "Creation failure changed the current view")
      smoke_conversion_window.poll
      smoke_conversion_window.smoke_capture(directory, "08-creation-error")
      smoke_conversion_window.smoke_configure(File.join(fixtures, "input.bam"), File.join(fixtures, "retry.d4"))
      smoke_conversion_window.smoke_create
    when 10
      return false if @conversion_worker.snapshot.state.active?
      UiSmoke.check(@conversion_worker.snapshot.state.succeeded?, "Could not retry after failure")
      shutdown
      @window.destroy
      UIng.quit
    end
    true
  end

  def smoke_stop
    shutdown
    @window.destroy
    UIng.quit
  end
end

screenshots = ARGV[0]?
Dir.mkdir(screenshots) if screenshots
fixtures = File.tempname("d4-plot-ui-smoke")
Dir.mkdir(fixtures)
File.write(File.join(fixtures, "genes.bed"), "chr1\t0\t5\tA\nchr1\t10\t15\tB\n")
header = HTS::Bam::Header.parse("@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:chr1\tLN:20\n")
HTS::Bam.open(File.join(fixtures, "input.bam"), "wb") do |bam|
  bam.write_header(header)
  bam.write(HTS::Bam::Record.new(header, "read", 0_u16, "chr1", 2_i64, 60_u8, "10M", "A" * 10, [30_u8] * 10, -1, 0_i64, 0_i64))
end
HTS::Bam.build_index(File.join(fixtures, "input.bam"), verbose: false)
FileUtils.cp(File.join(fixtures, "input.bam"), File.join(fixtures, "unindexed.bam"))
failure : Exception? = nil
begin
  D4Plot::Translations.setup("en")
  UIng.init
  app = D4Plot::App.new(D4Plot::App.create_menu_bar)
  step = 0
  started = Time.instant
  UIng.timer(700) do
    raise "UI smoke test timed out" if Time.instant - started > 60.seconds
    step += 1 if app.smoke_step(step, screenshots, fixtures)
    step > 10 ? 0 : 1
  rescue ex
    failure = ex
    app.smoke_stop
    0
  end
  app.run
ensure
  FileUtils.rm_rf(fixtures)
end
failure.try { |error| raise error }
puts "Native UI smoke test passed."
