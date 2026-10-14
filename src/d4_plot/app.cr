require "uing"
require "d4"
require "./i18n"
require "./preferences"
require "./view_loader"
require "./file_loader"
require "./track_list"
require "./plot_renderer"
require "./settings_window"
require "./log"
require "./toolbar"
require "./conversion_window"

module D4Plot
  class App
    PROGRAM_NAME = "D4 Plot Viewer"
    @window : UIng::Window
    @area : UIng::Area
    @handler = UIng::Area::Handler.new
    @renderer = PlotRenderer.new
    @settings = PlotSettings.new
    @settings_window : SettingsWindow?
    @conversion_worker = ConversionWorker.new
    @conversion_window : ConversionWindow?
    @conversion_status = UIng::Button.new(D4Plot.t("app.create_d4"))
    @quit_window : UIng::Window?
    @quitting = false
    @welcome = UIng::Box.new(:vertical, padded: true)
    @navigation = UIng::Box.new(:vertical, padded: true)
    @annotation_row = UIng::Box.new(:horizontal, padded: true)
    @loader = ViewLoader.new
    @file_loader : FileLoader
    @file_load_id : Int32?
    @file_append = false
    @file_region : String?
    @file_done : Proc(Bool, Nil)?
    @file_progress : FileLoadProgress?
    @history = ViewHistory.new
    @layers = [] of TrackLayer
    @selected = 0
    @completed_region : Region?
    @chromosomes = {} of String => UInt32
    @chromosome_names = [] of String
    @canvas_width = 1056
    @row_height = 220.0
    @add = UIng::Button.new(D4Plot.t("app.add_d4"))
    @remove = UIng::Button.new(D4Plot.t("app.remove"))
    @up = UIng::Button.new(D4Plot.t("app.up"))
    @down = UIng::Button.new(D4Plot.t("app.down"))
    @shared_y = UIng::Checkbox.new(D4Plot.t("app.shared_y"))
    @height = UIng::Combobox.new
    @source_entry = UIng::Entry.new(read_only: true)
    @annotation : AnnotationTrack?
    @annotation_path : String?
    @pending_annotation_path : String?
    @request_id = 0
    @requested_region : Region?
    @history_move = 0
    @updating = false
    @loading = false
    @closed = false
    @drag : Tuple(Float64, Region, Bool)?
    @file_label = UIng::Label.new(D4Plot.t("app.no_d4_file"))
    @track_list : TrackList
    @track_panel = UIng::Box.new(:vertical, padded: true)
    @sidebar_toggle = UIng::Button.new(D4Plot.t("app.show_tracks"))
    @chromosome_combo = UIng::Combobox.new
    @region_entry = UIng::Entry.new
    @go = UIng::Button.new(D4Plot.t("app.go"))
    @tools = Toolbar.new
    @details = UIng::Box.new(:vertical)
    @details_toggle = UIng::Button.new(D4Plot.t("app.show_details"))
    @details_visible = false
    @progress = UIng::ProgressBar.new
    @cancel_files = UIng::Button.new(D4Plot.t("toolbar.cancel"))
    @annotation_label = UIng::Label.new("")
    @remove_annotation = UIng::Button.new(D4Plot.t("app.remove"))
    @status = UIng::Label.new(D4Plot.t("app.status_ready"))
    @inspection = UIng::Label.new(D4Plot.t("app.inspection_short"))
    @view_summary = UIng::Label.new("")

    def self.create_menu_bar
      file = UIng::Menu.new(D4Plot.t("app.file"))
      open = file.append_item(D4Plot.t("app.open_d4"))
      create = file.append_item(D4Plot.t("app.create_d4_from_alignment"))
      export = file.append_item(D4Plot.t("app.export_bins"))
      settings = file.append_preferences_item
      file.append_quit_item
      help = UIng::Menu.new(D4Plot.t("app.help"))
      guide = help.append_item(D4Plot.t("app.navigation_help"))
      about = help.append_about_item
      {open: open, create: create, export: export, settings: settings, guide: guide, about: about}
    end

    def initialize(menu_items, @preferences = Preferences.load, @file_loader = FileLoader.new)
      @window = UIng::Window.new(PROGRAM_NAME, 1120, 780, menubar: true, margined: true)
      @area = UIng::Area.new(@handler, @canvas_width, 400)
      @track_list = TrackList.new(->(index : Int32) { select_layer(index); nil }, ->(index : Int32, visible : Bool) { toggle_layer(index, visible); nil })
      @settings = @preferences.settings
      @row_height = {160.0, 220.0, 300.0}[@preferences.height_index]
      @tools.native.display_mode = @settings.toolbar_display_mode
      setup_ui
      setup_handlers
      @window.on_content_size_changed { |_, _| resize_canvas }
      menu_items[:open].on_clicked { open_file_dialog }
      menu_items[:create].on_clicked { open_conversion }
      menu_items[:export].on_clicked { export_view }
      menu_items[:settings].on_clicked { open_settings }
      menu_items[:guide].on_clicked { show_help }
      menu_items[:about].on_clicked { @window.msg_box(PROGRAM_NAME, D4Plot.t("app.about")) }
      @window.on_closing do
        if confirm_quit
          shutdown
          UIng.quit
          true
        else
          false
        end
      end
      UIng.on_should_quit do
        if confirm_quit
          shutdown
          @window.destroy
          true
        else
          false
        end
      end
      UIng.timer(30) do
        if @closed
          0
        else
          receive_files
          receive_result
          poll_conversion
          1
        end
      end
      update_controls
    end

    def run(paths : Array(String) = [] of String, region : String? = nil)
      @window.show
      resize_canvas
      load_d4_files(paths, region) unless paths.empty?
      # Keep Crystal's scheduler responsive alongside the native UI loop.
      UIng.main_steps
      while UIng.main_step(false)
        sleep 8.milliseconds
      end
    ensure
      shutdown
      # Complete all native UI teardown before yielding to worker joins.
      UIng.uninit
      @loader.wait
      @file_loader.wait
      @conversion_worker.wait
    end

    private def row : UIng::Box
      box = UIng::Box.new(:horizontal)
      box.padded = true
      box
    end

    private def setup_ui
      root = UIng::Box.new(:vertical)
      root.padded = true
      # Intentional native-toolbar clearance, including icon-and-label mode.
      toolbar_gap = row
      root.append(toolbar_gap, false)
      @track_panel.append(@file_label, false)
      @track_panel.append(@add, false)
      @add.tooltip = D4Plot.t("app.add_d4_tip")
      @track_panel.append(@track_list.native, true)
      order = row
      order.append(@up, true)
      order.append(@down, true)
      @track_panel.append(order, false)
      @track_panel.append(@remove, false)

      location = row
      location.append(UIng::Label.new(D4Plot.t("app.chromosome")), false)
      location.append(@chromosome_combo, false)
      location.append(UIng::Label.new(D4Plot.t("app.region")), false)
      location.append(@region_entry, true)
      location.append(@go, false)
      @navigation.append(location, false)
      display = row
      display.append(@sidebar_toggle, false)
      display.append(UIng::Box.new(:horizontal), true)
      @shared_y.checked = @preferences.shared_y?
      display.append(@shared_y, false)
      display.append(UIng::Label.new(D4Plot.t("app.height")), false)
      ["app.compact", "app.normal", "app.large"].each { |key| @height.append(D4Plot.t(key)) }
      @height.selected = @preferences.height_index
      display.append(@height, false)
      display.append(@details_toggle, false)
      @navigation.append(display, false)
      root.append(@navigation, false)

      @annotation_label.set_minimum_size(0, -1)
      @annotation_row.append(@annotation_label, true)
      @annotation_row.append(@remove_annotation, false)
      root.append(@annotation_row, false)
      @annotation_row.hide
      @details.padded = true
      @source_entry.set_minimum_size(0, -1)
      @details.append(@source_entry, false)
      root.append(@details, false)
      @details.hide
      setup_welcome
      workspace = row
      workspace.append(@track_panel, false)
      plots = UIng::Box.new(:vertical)
      plots.append(@welcome, true)
      plots.append(@area, true)
      workspace.append(plots, true)
      root.append(workspace, true)
      setup_status_bar(root)
      @window.toolbar = @tools.native
      @window.child = root
    end

    private def centered(control : UIng::Control) : UIng::Box
      box = UIng::Box.new(:horizontal)
      box.append(UIng::Box.new(:horizontal), true)
      box.append(control, false)
      box.append(UIng::Box.new(:horizontal), true)
      box
    end

    private def setup_welcome
      title = UIng::Label.new(D4Plot.t("app.welcome_title"))
      title.font_size = 24
      description = UIng::Label.new(D4Plot.t("app.welcome_body"))
      description.font_size = 13
      @welcome.append(UIng::Box.new(:vertical), true)
      @welcome.append(centered(title), false)
      @welcome.append(centered(description), false)
      gap = UIng::Box.new(:vertical)
      gap.set_minimum_size(0, 16)
      @welcome.append(gap, false)
      welcome_buttons = UIng::Box.new(:horizontal)
      open = UIng::Button.new(D4Plot.t("app.open_d4"))
      open.tooltip = D4Plot.t("toolbar.open_tip")
      create = UIng::Button.new(D4Plot.t("app.create_d4"))
      open.set_minimum_size(168, 36)
      create.set_minimum_size(168, 36)
      open.on_clicked { open_file_dialog }
      create.on_clicked { open_conversion }
      welcome_buttons.append(open, false)
      button_gap = UIng::Box.new(:horizontal)
      button_gap.set_minimum_size(12, 0)
      welcome_buttons.append(button_gap, false)
      welcome_buttons.append(create, false)
      @welcome.append(centered(welcome_buttons), false)
      @welcome.append(UIng::Box.new(:vertical), true)
    end

    private def setup_status_bar(root : UIng::Box)
      root.append(UIng::Separator.new(:horizontal), false)
      status = row
      status.set_minimum_size(0, 28)
      @status.set_minimum_size(0, -1)
      @inspection.set_minimum_size(0, -1)
      @status.font_size = 12
      @inspection.font_size = 12
      @view_summary.font_size = 11
      @inspection.tooltip = D4Plot.t("app.inspection_hint")
      messages = UIng::Box.new(:horizontal)
      messages.append(@status, true)
      messages.append(@inspection, true)
      @inspection.hide
      status.append(messages, true)
      status.append(@view_summary, false)
      @view_summary.hide
      @progress.set_minimum_size(84, -1)
      status.append(@progress, false)
      status.append(@cancel_files, false)
      @cancel_files.hide
      status.append(@conversion_status, false)
      @conversion_status.hide
      root.append(status, false)
      @progress.value = -1
      @progress.hide
    end

    private def show_status(text : String)
      @status.text = text
      @status.tooltip = text
      @inspection.hide
      @status.show
    end

    private def show_inspection(text : String)
      @inspection.text = text.gsub(" | ", " · ")
      @inspection.tooltip = text
      @status.hide
      @inspection.show
    end

    private def reset_inspection
      @inspection.text = D4Plot.t("app.inspection_short")
      @inspection.tooltip = D4Plot.t("app.inspection_hint")
    end

    private def setup_handlers
      @sidebar_toggle.on_clicked { toggle_sidebar }
      @details_toggle.on_clicked do
        @details_visible = !@details_visible
        @details_visible ? @details.show : @details.hide
        @details_toggle.text = D4Plot.t(@details_visible ? "app.hide_details" : "app.show_details")
      end
      @tools.open.on_clicked { open_file_dialog }
      @tools.create.on_clicked { open_conversion }
      @conversion_status.on_clicked { open_conversion }
      @tools.annotations.on_clicked { open_annotation_dialog }
      @tools.settings.on_clicked { open_settings }
      @go.on_clicked { go_to_entry }
      @chromosome_combo.on_selected { |index| select_chromosome(index) unless @updating }
      @add.on_clicked { open_file_dialog(true) }
      @remove.on_clicked { remove_layer }
      @up.on_clicked { reorder_layer(-1) }
      @down.on_clicked { reorder_layer(1) }
      @shared_y.on_toggled do
        unless @updating
          save_view_preferences
          @area.queue_redraw_all
        end
      end
      @height.on_selected do |index|
        next if @updating
        save_view_preferences
        @row_height = {160.0, 220.0, 300.0}[@height.selected || 1]
        clear_drag
        resize_canvas
      end
      @tools.zoom_in.on_clicked { zoom(2.0) }
      @tools.zoom_out.on_clicked { zoom(0.5) }
      @tools.left.on_clicked { move(-0.5) }
      @tools.right.on_clicked { move(0.5) }
      @tools.whole.on_clicked { whole_chromosome }
      @tools.back.on_clicked { history_back }
      @tools.forward.on_clicked { history_forward }
      @tools.cancel.on_clicked { cancel_loading }
      @cancel_files.on_clicked { cancel_loading }
      @tools.export.on_clicked { export_view }
      @remove_annotation.on_clicked do
        @annotation_path = nil
        @pending_annotation_path = nil
        @annotation = nil
        @annotation_row.hide
        refresh
      end
      @handler.draw do |_, params|
        @renderer.draw(params, visible_layers, @completed_region, @settings, @chromosomes, @annotation, @loading || !@file_load_id.nil?,
          stack_geometry, @shared_y.checked?, selected_layer.try(&.source.key))
      end
      @handler.mouse_event { |_, event| mouse_event(event) }
      @handler.mouse_crossed do |_, left|
        if left
          @renderer.hover_index = nil
          reset_inspection
          @area.queue_redraw_all
        end
      end
      @handler.drag_broken { clear_drag; @area.queue_redraw_all }
      @handler.key_event { |_, event| key_event(event) }
    end

    private def selected_layer : TrackLayer?
      @layers[@selected]?
    end

    private def visible_layers
      @layers.select(&.visible?)
    end

    private def stack_geometry
      StackGeometry.new(@canvas_width.to_f64, @row_height, visible_layers.size)
    end

    private def resize_canvas
      sidebar = !@layers.empty? && @preferences.sidebar_visible?
      @canvas_width = Math.max(@window.content_size[0] - (sidebar ? 356 : 64), 240)
      @area.set_size(@canvas_width, stack_geometry.height(AnnotationRenderer.height_for(@annotation)))
      @area.queue_redraw_all
    end

    private def toggle_sidebar
      previous = @preferences.sidebar_visible?
      begin
        @preferences.sidebar_visible = !previous
        @preferences.save
      rescue ex : File::Error
        @preferences.sidebar_visible = previous
        show_error(D4Plot.t("app.preferences_error"), ex)
        return
      end
      clear_drag
      update_controls
      resize_canvas
    end

    private def open_file_dialog(append : Bool = false)
      if paths = @window.open_files
        load_d4_files(paths, append: append)
      end
    end

    private def load_d4_file(path : String, region_text : String? = nil, append : Bool = false, on_done : Proc(Bool, Nil)? = nil) : Bool
      load_d4_files([path], region_text, append, on_done)
    end

    private def load_d4_files(paths : Array(String), region_text : String? = nil, append : Bool = false, on_done : Proc(Bool, Nil)? = nil) : Bool
      return false if paths.empty?
      cancel_loading
      @file_load_id = @file_loader.submit(paths, append ? @layers.map(&.source) : [] of TrackSource)
      @file_append = append
      @file_region = region_text
      @file_done = on_done
      @file_progress = nil
      show_status(D4Plot.t("app.opening_files", current: 1, total: paths.size, name: short_name(paths.first)))
      @progress.value = 0
      update_controls
      true
    end

    private def receive_files
      return unless id = @file_load_id
      if (progress = @file_loader.progress) && progress.id == id && progress != @file_progress
        @file_progress = progress
        show_status(D4Plot.t("app.opening_files", current: progress.current, total: progress.total, name: short_name(progress.path)))
        @progress.value = (100 * (progress.current - 1) // progress.total)
      end
      return unless result = @file_loader.poll
      return unless result.id == id
      append, region_text, done = @file_append, @file_region, @file_done
      @file_load_id = nil
      @file_done = nil
      @file_progress = nil
      if error = result.error
        update_controls
        done.try(&.call(false))
        show_error(D4Plot.t("app.could_not_open"), Exception.new(error))
        return
      end
      existing = append ? @layers.to_h { |layer| {layer.source.key, layer} } : {} of Tuple(String, String) => TrackLayer
      @layers = result.sources.map { |source| existing[source.key]? || TrackLayer.new(source) }
      unless append
        @history.clear
        @completed_region = nil
        @annotation = nil
        @annotation_path = nil
        @pending_annotation_path = nil
        @annotation_row.hide
        @selected = 0
        @area.scroll_to(0, 0, 1, 1)
      end
      rebuild_layers(region_text)
      done.try(&.call(true))
    end

    private def rebuild_layers(region_text : String? = nil)
      previous = active_region
      @chromosomes = TrackSource.chromosomes(@layers.map(&.source))
      @chromosome_names = @chromosomes.keys
      @history.retain(@chromosomes)
      @selected = @selected.clamp(0, Math.max(@layers.size - 1, 0))
      @updating = true
      @track_list.replace(@layers, @selected)
      @chromosome_combo.clear
      @chromosome_names.each { |name| @chromosome_combo.append(name) }
      @updating = false
      @file_label.text = D4Plot.t("app.tracks", number: @layers.size)
      @window.title = D4Plot.t("app.window_title", number: @layers.size)
      select_layer(@selected, false)
      if @layers.empty?
        @completed_region = nil
        @annotation = nil
        @annotation_path = nil
        @annotation_row.hide
        @region_entry.text = ""
        @source_entry.text = ""
        @source_entry.tooltip = ""
        show_status(D4Plot.t("app.status_ready"))
        update_controls
      elsif region_text
        @region_entry.text = region_text
        go_to_entry
      elsif previous && @chromosomes[previous.chromosome]?.try { |size| previous.end1 <= size }
        request_view(previous)
      else
        @completed_region = nil
        select_chromosome(0)
      end
      resize_canvas
    end

    private def select_layer(index : Int32, scroll : Bool = true)
      return unless layer = @layers[index]?
      @selected = index
      @updating = true
      @track_list.select_row(index)
      @source_entry.text = D4Plot.t("app.source_details", path: layer.source.path,
        track: layer.source.name.empty? ? D4Plot.t("app.default_track") : layer.source.name,
        denominator: layer.source.denominator)
      @source_entry.tooltip = @source_entry.text
      @updating = false
      if scroll && (visible_index = visible_layers.index(layer))
        @area.scroll_to(0, stack_geometry.row_top(visible_index), 1, @row_height)
      end
      update_controls
      @area.queue_redraw_all
    end

    private def remove_layer
      return if @file_load_id
      return unless selected_layer
      cancel_loading
      @layers.delete_at(@selected)
      rebuild_layers
    end

    private def reorder_layer(delta : Int32)
      return if @file_load_id
      target = @selected + delta
      return unless 0 <= target < @layers.size
      # Ordering does not affect data identity or require a new read.
      @layers.swap(@selected, target)
      @selected = target
      @updating = true
      @track_list.replace(@layers, @selected)
      @updating = false
      select_layer(target)
    end

    private def toggle_layer(index : Int32, visible : Bool)
      return if @file_load_id
      return unless layer = @layers[index]?
      layer.visible = visible
      @track_list.changed(index)
      select_layer(index, false)
      clear_drag
      resize_canvas
      refresh
    end

    private def save_view_preferences
      previous_height, previous_shared = @preferences.height_index, @preferences.shared_y?
      begin
        @preferences.height_index = @height.selected || 1
        @preferences.shared_y = @shared_y.checked?
        @preferences.save
      rescue ex : File::Error
        @preferences.height_index = previous_height
        @preferences.shared_y = previous_shared
        @updating = true
        @height.selected = previous_height
        @shared_y.checked = previous_shared
        @updating = false
        show_error(D4Plot.t("app.preferences_error"), ex)
      end
    end

    private def select_chromosome(index : Int32)
      return unless name = @chromosome_names[index]?
      request_view(Region.new(name, 1_u32, @chromosomes[name]))
    end

    private def go_to_entry
      request_view(Region.resolve(@region_entry.text || "", @chromosomes))
    rescue ex
      show_error(D4Plot.t("app.check_region"), ex)
    end

    private def request_view(region : Region, history_move : Int32 = 0)
      return if @layers.empty? || @file_load_id
      region.validate!(@chromosomes)
      rollback_history
      @history_move = history_move
      @requested_region = region
      @region_entry.text = region.to_s
      @updating = true
      @chromosome_combo.selected = @chromosome_names.index(region.chromosome)
      @updating = false
      clear_drag
      @renderer.hover_index = nil
      @loading = true
      show_status(D4Plot.t("app.loading", region: region))
      @status.tooltip = D4Plot.t("app.loading_inspection")
      @request_id = @loader.submit(visible_layers.map(&.source), region, @settings.point_count, @settings.use_sum_index?, @pending_annotation_path || @annotation_path, @settings.annotation_feature_limit, @annotation_path)
      update_controls
      @area.queue_redraw_all
    end

    private def receive_result
      return unless result = @loader.poll
      return unless result.request.id == @request_id && @loading
      @loading = false
      @requested_region = nil
      if error = result.error
        rollback_history
        show_status(D4Plot.t("app.read_failed", error: error))
        restore_location
      else
        # Publish the whole generation together. A failed/missing track has an
        # explicit empty row; old-coordinate samples never survive a commit.
        samples = result.layers.to_h { |sample| {sample.source.key, sample} }
        @layers.each do |layer|
          sample = samples[layer.source.key]?
          layer.view = sample.try(&.view)
          layer.error = sample.try(&.error)
        end
        @completed_region = result.request.region
        @annotation = result.annotation_track
        if error = result.annotation_error
          @annotation_label.text = D4Plot.t("app.annotation_load_failed",
            selection: D4Plot.t(@annotation_path ? "app.previous_selection_kept" : "app.no_annotation_selected"))
          @annotation_label.tooltip = error
          @annotation_row.show
        else
          @annotation_path = result.request.annotation_path
          update_annotation_label
        end
        @pending_annotation_path = nil
        @history.record(result.request.region) if @history_move == 0
        @history_move = 0
        @region_entry.text = result.request.region.to_s
        failed = result.layers.count { |sample| !sample.error.nil? }
        @view_summary.text = D4Plot.t("app.view_summary", bases: DisplayFormat.position(result.request.region.length), tracks: result.layers.size)
        if failed > 0
          @view_summary.text = "#{@view_summary.text} · #{D4Plot.t("app.unavailable_summary", failed: failed)}"
        end
        @view_summary.tooltip = D4Plot.t("app.view_status", bases: DisplayFormat.position(result.request.region.length),
          tracks: result.layers.size, failed: failed, elapsed: result.elapsed_ms.round(1))
        @status.hide
        @inspection.show
        reset_inspection
      end
      update_controls
      resize_canvas
    end

    private def active_region : Region?
      @requested_region || @completed_region
    end

    private def zoom(factor : Float64, fraction : Float64 = 0.5)
      return unless region = active_region
      length = Math.max((region.length / factor).round.to_i64, 1_i64)
      left = (region.start0 + region.length * fraction - length * fraction).round.to_i64
      request_view(Region.bounded(region.chromosome, left, length, @chromosomes[region.chromosome]))
    end

    private def move(fraction : Float64)
      return unless region = active_region
      delta = (region.length * fraction).round.to_i64
      delta = fraction < 0 ? -1_i64 : 1_i64 if delta == 0
      request_view(Region.bounded(region.chromosome, region.start0.to_i64 + delta, region.length.to_i64, @chromosomes[region.chromosome]))
    end

    private def whole_chromosome
      return unless region = active_region
      request_view(Region.new(region.chromosome, 1_u32, @chromosomes[region.chromosome]))
    end

    private def history_back
      return if @loading || @file_load_id
      if region = @history.back
        request_view(region, -1)
      end
    end

    private def history_forward
      return if @loading || @file_load_id
      if region = @history.forward
        request_view(region, 1)
      end
    end

    private def rollback_history
      @history.forward if @history_move == -1
      @history.back if @history_move == 1
      @history_move = 0
    end

    private def cancel_loading
      was_opening = !@file_load_id.nil?
      @file_loader.cancel
      @file_load_id = nil
      @file_progress = nil
      done = @file_done
      @file_done = nil
      done.try(&.call(false))
      was_loading = @loading
      clear_drag
      @loader.cancel
      @loading = false
      @requested_region = nil
      if @pending_annotation_path
        @pending_annotation_path = nil
        update_annotation_label
      end
      rollback_history
      restore_location
      show_status(D4Plot.t("app.loading_cancelled")) if was_loading
      show_status(D4Plot.t("app.files_cancelled")) if was_opening
      update_controls
      @area.queue_redraw_all
    end

    private def restore_location
      if region = @completed_region
        @region_entry.text = region.to_s
        reset_inspection
        @updating = true
        @chromosome_combo.selected = @chromosome_names.index(region.chromosome)
        @updating = false
      end
    end

    private def open_annotation_dialog
      return if @layers.empty? || @file_load_id
      if path = @window.open_file
        @pending_annotation_path = path
        @annotation_label.text = D4Plot.t("app.loading_annotation", name: short_name(path))
        @annotation_label.tooltip = path
        @annotation_row.show
        refresh
      end
    end

    private def refresh
      if region = active_region
        request_view(region)
      else
        update_controls
        @area.queue_redraw_all
      end
    end

    private def open_settings
      if window = @settings_window
        window.show
      else
        window = SettingsWindow.new(@settings, @preferences, @window, ->(reload_data : Bool) {
          @settings = @preferences.settings
          @tools.native.display_mode = @settings.toolbar_display_mode
          reload_data ? refresh : @area.queue_redraw_all
        }, -> { @settings_window = nil })
        @settings_window = window
        window.show
      end
    end

    private def export_view
      return unless layer = selected_layer
      return unless view = layer.view
      return if @loading || @file_load_id || !layer.visible? || view.region != @completed_region
      if path = @window.save_file
        (@layers.map(&.source.path) + [@annotation_path].compact).each do |source|
          if File.expand_path(path) == File.expand_path(source) || (File.exists?(path) && File.same?(path, source))
            raise D4Plot.t("app.export_conflict")
          end
        end
        File.open(path, "w") do |io|
          io << "# Source: " << layer.source.path.gsub(/[\r\n]/, " ") << "; track: " << layer.source.name.gsub(/[\r\n]/, " ") << '\n'
          view.write_bedgraph(io)
        end
        show_status(D4Plot.t("app.exported", number: view.points.size, name: File.basename(path)))
      end
    rescue ex
      show_error(D4Plot.t("app.could_not_export"), ex)
    end

    private def update_controls
      if @layers.empty?
        @navigation.hide
        @track_panel.hide
        @sidebar_toggle.disable
        @welcome.show
        @area.hide
        @inspection.hide
      else
        @navigation.show
        @preferences.sidebar_visible? ? @track_panel.show : @track_panel.hide
        @sidebar_toggle.enable
        @welcome.hide
        @area.show
      end
      @details_visible && !@layers.empty? ? @details.show : @details.hide
      if @completed_region && !@loading && @file_load_id.nil? && !@layers.empty?
        @view_summary.show
      else
        @view_summary.hide
      end
      @sidebar_toggle.text = D4Plot.t(@track_panel.visible? ? "app.hide_tracks" : "app.show_tracks")
      @progress.value = -1 if @loading && @file_load_id.nil?
      @loading || @file_load_id ? @progress.show : @progress.hide
      @file_load_id ? @cancel_files.show : @cancel_files.hide
      update_region_controls
      update_layer_controls
      update_history_controls
      @annotation_row.visible? && @file_load_id.nil? ? @remove_annotation.enable : @remove_annotation.disable
      @remove_annotation.text = D4Plot.t(@annotation_path || @pending_annotation_path ? "app.remove" : "app.dismiss")
    end

    private def update_region_controls
      ready = !@layers.empty? && !@chromosomes.empty? && @file_load_id.nil?
      [@go, @chromosome_combo, @region_entry].each do |control|
        ready ? control.enable : control.disable
      end
      [@tools.annotations, @tools.left, @tools.right, @tools.zoom_in, @tools.zoom_out, @tools.whole].each do |control|
        ready ? control.enable : control.disable
      end
      @loading || @file_load_id ? @tools.cancel.enable : @tools.cancel.disable
    end

    private def update_layer_controls
      busy = !@file_load_id.nil?
      busy ? @track_list.native.disable : @track_list.native.enable
      busy ? @add.disable : @add.enable
      @layers.empty? || busy ? @remove.disable : @remove.enable
      @selected > 0 && !busy ? @up.enable : @up.disable
      @selected < @layers.size - 1 && !busy ? @down.enable : @down.disable
      layer = selected_layer
      exportable = layer && layer.visible? && layer.view.try(&.region) == @completed_region && !layer.view.nil? && !@loading && !busy
      exportable ? @tools.export.enable : @tools.export.disable
    end

    private def update_history_controls
      @history.back? && !@loading && @file_load_id.nil? ? @tools.back.enable : @tools.back.disable
      @history.forward? && !@loading && @file_load_id.nil? ? @tools.forward.enable : @tools.forward.disable
    end

    private def mouse_event(event)
      return unless region = @completed_region
      return if @loading || @file_load_id
      stack = stack_geometry
      layers = visible_layers
      index = stack.index_at(event.y)
      layer = index ? layers[index]? : nil
      layout = stack.plot(index || 0)
      fraction = layout.fraction(event.x)
      inside = !layer.nil? && layout.contains?(event.x, event.y)
      inspect_mouse(layer, region, fraction, inside)
      if event.down == 1
        handle_mouse_down(event, layer, index, stack, region, layout, fraction, inside)
      elsif event.up == 1
        finish_drag(fraction, layout)
      elsif event.up == 3 && inside
        zoom(0.5, fraction)
      elsif drag = @drag
        preview_drag(drag, fraction)
      end
      @area.queue_redraw_all
    end

    private def inspect_mouse(layer : TrackLayer?, region : Region, fraction : Float64, inside : Bool)
      @renderer.hover_index = nil
      @renderer.hover_layer = nil
      return unless inside && @drag.nil?
      return unless layer
      return unless view = layer.view
      return unless view.region == region
      bin = view.bin_at(fraction)
      show_inspection("#{layer.source.label} · #{view.inspect_bin(bin)}")
      @renderer.hover_index = bin
      @renderer.hover_layer = layer.source.key
    end

    private def handle_mouse_down(event, layer : TrackLayer?, index : Int32?, stack : StackGeometry,
                                  region : Region, layout : PlotGeometry, fraction : Float64, inside : Bool)
      if layer && index
        if layer_index = @layers.index(layer)
          # A title click selects a track without changing the genomic region.
          title_clicked = event.y < stack.row_top(index) + 28
          select_layer(layer_index, false) if title_clicked || inside
          return if title_clicked
        end
      end
      start_mouse_action(event, region, layout, fraction, inside)
    end

    private def preview_drag(drag : Tuple(Float64, Region, Bool), fraction : Float64)
      if drag[2]
        @renderer.selection = {drag[0], fraction}
        show_inspection(D4Plot.t("app.release_selection"))
      else
        preview = drag[1].pan(drag[0] - fraction, @chromosomes[drag[1].chromosome])
        @renderer.preview_region = preview
        show_inspection(D4Plot.t("app.preview_pan", region: preview))
      end
    end

    private def start_mouse_action(event, region, layout, fraction, inside)
      if event.y >= 34 && event.y <= 56 && event.x >= layout.left && event.x <= layout.left + layout.width
        size = @chromosomes[region.chromosome]
        left = (fraction * size - region.length / 2).round.to_i64
        request_view(Region.bounded(region.chromosome, left, region.length.to_i64, size))
      elsif inside
        if event.count == 2
          zoom(2.0, fraction)
        else
          @drag = {fraction, region, event.modifiers.shift?}
        end
      end
    end

    private def finish_drag(fraction, layout)
      drag = @drag
      clear_drag
      return unless drag
      start, region, selecting = drag
      return if (fraction - start).abs * layout.width < 4
      if selecting
        left, right = {start, fraction}.minmax
        start0 = region.start0.to_i64 + (left * region.length).floor.to_i64
        end0 = region.start0.to_i64 + (right * region.length).ceil.to_i64
        request_view(Region.bounded(region.chromosome, start0, end0 - start0, @chromosomes[region.chromosome]))
      else
        request_view(region.pan(start - fraction, @chromosomes[region.chromosome]))
      end
    end

    private def clear_drag
      @drag = nil
      @renderer.selection = nil
      @renderer.preview_region = nil
      @renderer.hover_index = nil
      @renderer.hover_layer = nil
      reset_inspection
    end

    private def key_event(event) : Bool
      return false if event.up?
      case event.ext_key
      when UIng::Area::ExtKey::Left  then move(-0.5)
      when UIng::Area::ExtKey::Right then move(0.5)
      when UIng::Area::ExtKey::Home  then whole_chromosome
      when UIng::Area::ExtKey::Escape
        @drag ? clear_drag : cancel_loading
        @area.queue_redraw_all
      else
        case event.key
        when '+', '='   then zoom(2.0)
        when '-'        then zoom(0.5)
        when '\r', '\n' then go_to_entry
        else                 return false
        end
      end
      true
    end

    private def show_help
      @window.msg_box(D4Plot.t("app.help_title"), D4Plot.t("app.help_body"))
    end

    private def short_name(path)
      name = File.basename(path)
      name.size > 64 ? "#{name[0, 40]}…#{name[-20, 20]}" : name
    end

    private def update_annotation_label
      if path = @annotation_path
        @annotation_label.text = D4Plot.t("app.annotation_label", name: short_name(path))
        @annotation_label.tooltip = path
        @annotation_row.show
      else
        @annotation_row.hide
      end
    end

    private def open_conversion
      window = @conversion_window ||= ConversionWindow.new(@conversion_worker, ->(path : String, done : Proc(Bool, Nil)) { load_d4_file(path, append: true, on_done: done) })
      window.show
    end

    private def poll_conversion
      @conversion_window.try(&.poll)
      state = @conversion_worker.snapshot.state
      if state.idle?
        @conversion_status.hide
      else
        @conversion_status.show
        @conversion_status.text = case state
                                  when .running?    then D4Plot.t("app.creating")
                                  when .cancelling? then D4Plot.t("app.cancelling")
                                  when .succeeded?  then D4Plot.t("app.ready_for_review")
                                  when .cancelled?  then D4Plot.t("app.creation_cancelled")
                                  else                   D4Plot.t("app.creation_failed")
                                  end
      end
      if @quitting && !state.active?
        shutdown
        @window.destroy
        UIng.quit
      end
    end

    private def confirm_quit : Bool
      return true unless @conversion_worker.snapshot.state.active?
      if window = @quit_window
        window.show
        return false
      end
      window = UIng::Window.new(D4Plot.t("app.quit_creation_title"), 440, 150, margined: true)
      root = UIng::Box.new(:vertical, padded: true)
      message = UIng::Label.new(D4Plot.t("app.quit_creation_message"))
      root.append(message, true)
      buttons = row
      keep = UIng::Button.new(D4Plot.t("app.keep_working"))
      quit = UIng::Button.new(D4Plot.t("app.cancel_creation_and_quit"))
      buttons.append(keep, false)
      buttons.append(quit, false)
      root.append(buttons, false)
      window.child = root
      keep.on_clicked { window.destroy; @quit_window = nil }
      quit.on_clicked do
        @quitting = true
        @conversion_worker.cancel
        keep.disable
        quit.disable
        message.text = D4Plot.t("app.quitting_wait")
      end
      window.on_closing do
        if @quitting
          false
        else
          @quit_window = nil
          true
        end
      end
      @quit_window = window
      window.show
      false
    end

    private def show_error(title, error)
      message = error.message || error.class.name
      show_status(message)
      @window.msg_box_error(title, message)
    end

    private def shutdown
      return if @closed
      @closed = true
      @settings_window.try(&.destroy)
      @settings_window = nil
      @conversion_worker.cancel
      @conversion_window.try(&.destroy)
      @conversion_window = nil
      @quit_window.try(&.destroy)
      @quit_window = nil
      @loader.close
      @file_loader.close
      @file_done = nil
      @track_panel.delete(@track_list.native)
      @track_list.free
      @window.toolbar = nil
      @tools.free
    end
  end
end
