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
    fun object_getClass(object : Void*) : Void*
    fun class_getMethodImplementation(klass : Void*, selector : Void*) : Void*
  end

  lib SmokeCommand
    fun system(command : UInt8*) : Int32
  end
{% end %}

module UiSmoke
  # Atomic is a struct: expose a reference wrapper so getters don't return
  # copies whose set operations would never reach the shared flag.
  class Flag
    @value = Atomic(Bool).new(false)

    def get : Bool
      @value.get
    end

    def set(value : Bool) : Nil
      @value.set(value)
    end
  end

  class_getter slow_writes = Flag.new
  class_getter writing = Flag.new
  class_getter background_progress = Flag.new
  class_property responsive_ticks = 0

  def self.tick
    D4Plot::UIRuntime.check_thread!
    self.responsive_ticks += 1 if writing.get
  end

  def self.click(button : UIng::Button)
    D4Plot::UIRuntime.check_thread!
    {% if flag?(:darwin) %}
      handle = button.handle
      selector = SmokeObjC.sel_registerName("performClick:")
      implementation = SmokeObjC.class_getMethodImplementation(SmokeObjC.object_getClass(handle), selector)
      action = Proc(Pointer(Void), Pointer(Void), Pointer(Void), Nil).new(implementation, Pointer(Void).null)
      action.call(handle, selector, Pointer(Void).null)
    {% else %}
      button.smoke_click
    {% end %}
    D4Plot::UIRuntime.check_thread!
  end

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

class UIng::Button
  def smoke_click
    callback = @on_clicked_box || raise "Button callback is missing"
    Box(Proc(Nil)).unbox(callback).call
  end
end

class D4Plot::Preferences
  def self.write(path : String, data : String) : Nil
    if UiSmoke.slow_writes.get
      UiSmoke.writing.set(true)
      # Longer than Cocoa's performClick animation, so timer progress measures
      # overlap with disk work rather than the synthetic button animation.
      sleep 250.milliseconds
    end
    previous_def
  ensure
    UiSmoke.writing.set(false)
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
    UiSmoke.check(!@reference_section.visible? && !@cancel.visible? && !@add.visible?, "Basic settings contain irrelevant controls")
    @input.text = "reference-check.cram"
    sync_reference(true)
    UiSmoke.check(@reference_section.visible? && @reference.enabled?, "CRAM reference controls are missing")
    @input.text = @draft.input
    sync_reference(true)
    @tabs.selected = 1
    @draft.advanced_open = true
    @exclude.text = "0x704"
    update_advanced_label
    UiSmoke.check(@advanced_notice.visible?, "Modified advanced settings are not indicated")
  end

  def smoke_create
    create
  end

  def smoke_hide
    @window.hide
  end

  def smoke_add
    add_to_view
  end

  def smoke_added
    UiSmoke.check(@added && !@add.enabled?, "Add to view did not update its completion state")
    UiSmoke.check(@add.visible? && @create.visible? && !@cancel.visible?, "Completed conversion actions are incorrect")
  end

  def smoke_preserved(input, output)
    UiSmoke.check(@input.text == input && @output.text == output, "Conversion draft was lost on reopen")
    UiSmoke.check(@draft.advanced_open? && @tabs.selected == 1, "Advanced tab was lost on reopen")
  end
end

class D4Plot::SettingsWindow
  def smoke_apply
    @toolbar_mode.selected = 2
    @bins.value = 512
    @color.set_color(0.8, 0.2, 0.1, 1.0)
    apply_settings
  end

  def smoke_capture(directory)
    UiSmoke.capture(@window, directory, "11-display-settings")
  end

  def smoke_close
    @on_close.call
    destroy
  end
end

class D4Plot::App
  @smoke_sidebar_width = 0
  @smoke_io_pending = false
  @smoke_io_done = false
  @smoke_io_error : Exception?
  @smoke_clicks_done = false

  private def smoke_io(&work : -> Nil) : Bool
    if error = @smoke_io_error
      raise error
    end
    if @smoke_io_done
      @smoke_io_done = false
      return true
    end
    unless @smoke_io_pending
      @smoke_io_pending = true
      @background_io.submit(work) do |failure|
        @smoke_io_error = failure
        @smoke_io_pending = false
        @smoke_io_done = true
      end
    end
    false
  end

  def smoke_step(step, directory, fixtures)
    if step <= 5
      smoke_early_step(step, directory, fixtures)
    elsif step <= 10
      smoke_late_step(step, directory, fixtures)
    elsif step <= 19
      smoke_tracks_step(step, directory, fixtures)
    else
      smoke_io_stress_step(step, fixtures)
    end
  end

  private def smoke_conversion_window
    @conversion_window || raise "Conversion window is not open"
  end

  private def smoke_early_step(step, directory, fixtures)
    case step
    when 0
      UiSmoke.check(@welcome.visible?, "Empty state is missing")
      UiSmoke.check(!@navigation.visible? && @status.visible? && !@inspection.visible?, "Empty state contains inactive navigation or duplicate status messages")
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
      return false if @loading || @file_load_id
      UiSmoke.check(@layers.size == 1, "Add to view failed")
      smoke_conversion_window.smoke_added
      @pending_annotation_path = File.join(fixtures, "genes.gtf.gz")
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
      UiSmoke.check(@annotation_path == File.join(fixtures, "genes.gtf.gz"), "Annotation selection was not committed")
      UiSmoke.capture(@window, directory, "05-view-annotation")
      @pending_annotation_path = File.join(fixtures, "missing.bed")
      layout = stack_geometry.plot(0)
      event = UIng::LibUI::AreaMouseEvent.new(x: layout.left + layout.width * 0.25,
        y: layout.top + 10, down: 1, count: 1, modifiers: UIng::Area::Modifiers::Shift)
      mouse_event(event)
      event.down = 0
      event.up = 1
      event.x = layout.left + layout.width * 0.75
      mouse_event(event)
    when 7
      return false if @loading
      UiSmoke.check(@annotation_path == File.join(fixtures, "genes.gtf.gz"), "Failed replacement lost the annotation")
      UiSmoke.check(@annotation.try(&.features.first?.try(&.name)) == "B", "Fallback used stale coordinates")
      UiSmoke.check(@completed_region == D4Plot::Region.new("chr1", 6_u32, 15_u32), "Shift-drag did not zoom to the selected region")
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
      UiSmoke.check(@layers.size == 1 && @annotation_path == File.join(fixtures, "genes.gtf.gz"), "Creation failure changed the current view")
      smoke_conversion_window.poll
      smoke_conversion_window.smoke_capture(directory, "08-creation-error")
      smoke_conversion_window.smoke_configure(File.join(fixtures, "input.bam"), File.join(fixtures, "retry.d4"))
      smoke_conversion_window.smoke_create
    when 10
      return false if @conversion_worker.snapshot.state.active?
      UiSmoke.check(@conversion_worker.snapshot.state.succeeded?, "Could not retry after failure")
      @window.set_content_size(1120, 780)
      load_d4_files([File.join(fixtures, "output.d4"), File.join(fixtures, "retry.d4")])
    end
    true
  end

  private def smoke_tracks_step(step, directory, fixtures)
    case step
    when 11..13 then smoke_track_settings_step(step, directory, fixtures)
    when 14..16 then smoke_track_loading_step(step, directory, fixtures)
    when 17..19 then smoke_sidebar_step(step, directory)
    else             true
    end
  end

  private def smoke_track_settings_step(step, directory, fixtures)
    case step
    when 11 then smoke_opened_tracks_step(directory)
    when 12 then smoke_track_preferences_step(directory)
    when 13 then smoke_saved_settings_step(directory, fixtures)
    else         true
    end
  end

  private def smoke_track_loading_step(step, directory, fixtures)
    case step
    when 14 then smoke_file_progress_step(directory, fixtures)
    when 15 then smoke_stale_file_step
    when 16 then smoke_removed_track_step
    else         true
    end
  end

  private def smoke_opened_tracks_step(directory)
    return false if @loading || @file_load_id
    UiSmoke.check(@layers.size == 2 && @annotation_path.nil?, "Batch opening did not replace the workspace")
    UiSmoke.check(@track_list.native.selection.rows == [0], "Initial track selection was lost")
    UiSmoke.check(@navigation.visible? && @inspection.visible? && !@status.visible? && @view_summary.visible?, "Idle status bar did not show inspection and summary")
    UiSmoke.capture(@window, directory, "09-track-list")
    select_layer(1)
    toggle_layer(0, false)
    select_layer(1)
    reorder_layer(-1)
    true
  end

  private def smoke_track_preferences_step(directory)
    return false if @loading
    UiSmoke.check(@layers.first.source.path.ends_with?("retry.d4"), "Track order was not updated")
    UiSmoke.check(!@layers.last.visible?, "Hidden track state was lost")
    UiSmoke.check(@track_list.native.selection.rows == [0], "Track selection did not follow reordering")
    UiSmoke.capture(@window, directory, "10-hidden-track")
    @height.selected = 0
    @shared_y.checked = true
    save_view_preferences
    open_settings
    smoke_settings_window.smoke_apply
    true
  end

  private def smoke_saved_settings_step(directory, fixtures)
    return false if @loading
    path = @preferences.path
    expected_color = @settings.plot_color
    return false unless smoke_io do
                          saved = Preferences.load(path)
                          UiSmoke.check(saved.height_index == 0 && saved.shared_y?, "Layout preferences did not persist")
                          UiSmoke.check(saved.settings.point_count == 512 && saved.settings.plot_color == expected_color, "Display settings did not persist")
                          UiSmoke.check(saved.settings.toolbar_display_mode.icon_only?, "Toolbar preference did not persist")
                          FileUtils.cp(File.join(fixtures, "output.d4"), File.join(fixtures, "slow.d4"))
                        end
    smoke_settings_window.smoke_capture(directory)
    smoke_settings_window.smoke_close
    load_d4_files([File.join(fixtures, "slow.d4"), File.join(fixtures, "retry.d4")], append: true)
    true
  end

  private def smoke_file_progress_step(directory, fixtures)
    UiSmoke.check(!@file_load_id.nil? && @cancel_files.visible?, "File progress did not remain responsive")
    UiSmoke.check(@status.visible? && !@inspection.visible? && !@view_summary.visible?, "Loading status was mixed with idle hints or stale metrics")
    UiSmoke.capture(@window, directory, "12-opening-files")
    cancel_loading
    UiSmoke.check(@layers.size == 2 && !@layers.last.visible?, "Cancelling changed the previous workspace")
    UiSmoke.check(!@progress.visible? && !@cancel_files.visible?, "Cancelled progress remained visible")
    load_d4_files([File.join(fixtures, "retry.d4")], append: true)
    true
  end

  private def smoke_stale_file_step
    return false if @loading || @file_load_id
    UiSmoke.check(@layers.size == 2, "Duplicate or cancelled file was added")
    UiSmoke.check(@layers.none?(&.source.path.ends_with?("slow.d4")), "A stale file result was applied")
    remove_layer
    true
  end

  private def smoke_removed_track_step
    return false if @loading
    UiSmoke.check(@layers.size == 1 && !@layers.first.visible?, "Removing a track lost the remaining visibility state")
    @smoke_sidebar_width = @canvas_width
    toggle_layer(0, true)
    UiSmoke.click(@sidebar_toggle)
    true
  end

  private def smoke_sidebar_step(step, directory)
    case step
    when 17
      return false if @loading
      UiSmoke.check(!@track_panel.visible? && @sidebar_toggle.enabled?, "Hidden sidebar cannot be restored")
      UiSmoke.check(@canvas_width > @smoke_sidebar_width, "Hiding the sidebar did not expand the plot")
      return false unless smoke_sidebar_saved(false)
      UiSmoke.capture(@window, directory, "13-sidebar-hidden")
      refresh
    when 18
      return false if @loading
      UiSmoke.check(!@track_panel.visible?, "Refreshing unexpectedly showed the sidebar")
      UiSmoke.click(@sidebar_toggle)
    when 19
      UiSmoke.check(@track_panel.visible? && @canvas_width == @smoke_sidebar_width, "Restoring the sidebar did not restore the plot width")
      UiSmoke.check(@layers.size == 1 && @layers.first.visible? && @track_list.native.selection.rows == [0], "Toggling the sidebar changed track state")
      return false unless smoke_sidebar_saved(true)
      UiSmoke.capture(@window, directory, "14-sidebar-restored")
    end
    true
  end

  private def smoke_sidebar_saved(visible : Bool) : Bool
    path = @preferences.path
    smoke_io do
      UiSmoke.check(Preferences.load(path).sidebar_visible? == visible, "Sidebar preference was not saved")
    end
  end

  private def smoke_io_stress_step(step, fixtures)
    if step == 20
      UiSmoke.slow_writes.set(true)
      spawn do
        sleep 100.milliseconds
        UiSmoke.background_progress.set(true)
      end
      clicks = 0
      UIng.timer(10) do
        UiSmoke.click(@sidebar_toggle)
        clicks += 1
        @smoke_clicks_done = clicks == 40
        @smoke_clicks_done ? 0 : 1
      end
    else
      return false unless @smoke_clicks_done
      return false unless smoke_verify_io_stress(fixtures)
      UiSmoke.check(UiSmoke.responsive_ticks >= 5, "UI timer stalled during slow saves (#{UiSmoke.responsive_ticks} ticks)")
      UiSmoke.check(UiSmoke.background_progress.get, "Ordinary fibers stalled during the native loop")
      UiSmoke.check(@track_panel.visible?, "Repeated sidebar clicks lost the final state")
      smoke_stop
    end
    true
  end

  private def smoke_verify_io_stress(fixtures) : Bool
    path = File.join(fixtures, "export.bedgraph")
    preferences_path = @preferences.path
    # Enqueue once, before the verification job, after all sidebar saves.
    export_view(path) unless @smoke_io_pending || @smoke_io_done
    smoke_io do
      UiSmoke.check(Preferences.load(preferences_path).sidebar_visible?, "Final slow save was lost")
      UiSmoke.check(File.read(path).includes?("chr1\t"), "Asynchronous export is missing")
    end
  end

  private def smoke_settings_window : SettingsWindow
    @settings_window || raise "Settings window was not opened"
  end

  def smoke_stop
    shutdown
    @window.destroy
    UIng.quit
  end
end

D4Plot::UIRuntime.prepare
screenshots = ARGV[0]?
fixtures = D4Plot::UIRuntime.load do
  Dir.mkdir(screenshots) if screenshots
  fixture_path = File.tempname("d4-plot-ui-smoke")
  Dir.mkdir(fixture_path)
  HTS::Bgzf.open(File.join(fixture_path, "genes.gtf.gz"), "wz") do |file|
    file.puts("chr1\tref\tgene\t1\t5\t.\t+\t.\tgene_name \"A\";")
    file.puts("chr1\tref\texon\t11\t15\t.\t+\t.\tgene_name \"B\";")
  end
  HTS::Tabix.build_index(File.join(fixture_path, "genes.gtf.gz"), preset: :gff, verbose: false)
  header = HTS::Bam::Header.parse("@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:chr1\tLN:20\n")
  HTS::Bam.open(File.join(fixture_path, "input.bam"), "wb") do |bam|
    bam.write_header(header)
    bam.write(HTS::Bam::Record.new(header, "read", 0_u16, "chr1", 2_i64, 60_u8, "10M", "A" * 10, [30_u8] * 10, -1, 0_i64, 0_i64))
  end
  HTS::Bam.build_index(File.join(fixture_path, "input.bam"), verbose: false)
  FileUtils.cp(File.join(fixture_path, "input.bam"), File.join(fixture_path, "unindexed.bam"))
  fixture_path
end
failure : Exception? = nil
begin
  D4Plot::Translations.setup(ENV["D4_PLOT_SMOKE_LOCALE"]? || "en")
  D4Plot::UIRuntime.check_thread!
  UIng.init
  preferences = D4Plot::Preferences.new(File.join(fixtures, "settings.json"), I18n.locale)
  file_loader = D4Plot::FileLoader.new(->(path : String, _cancelled : Proc(Bool)) {
    sleep 2.seconds if path.ends_with?("slow.d4")
    D4Plot::TrackSource.load(path)
  })
  app = D4Plot::App.new(D4Plot::App.create_menu_bar, preferences, file_loader)
  UIng.on_error { |error, _context| failure = error }
  UIng.timer(10) { UiSmoke.tick; 1 }
  step = 0
  started = Time.instant
  UIng.timer(700) do
    D4Plot::UIRuntime.check_thread!
    if error = failure
      raise error
    end
    raise "UI smoke test timed out" if Time.instant - started > 60.seconds
    step += 1 if app.smoke_step(step, screenshots, fixtures)
    step > 21 ? 0 : 1
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
puts "Native UI smoke test passed (#{UiSmoke.responsive_ticks} UI ticks during slow writes)."
