require "uing"
require "d4"
require "./view_loader"
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
    @conversion_status = UIng::Button.new("Create D4…")
    @quit_window : UIng::Window?
    @quitting = false
    @welcome = UIng::Box.new(:vertical, padded: true)
    @annotation_row = UIng::Box.new(:horizontal, padded: true)
    @loader = ViewLoader.new
    @history = ViewHistory.new
    @layers = [] of TrackLayer
    @selected = 0
    @completed_region : Region?
    @chromosomes = {} of String => UInt32
    @chromosome_names = [] of String
    @canvas_width = 1056
    @row_height = 220.0
    @add = UIng::Button.new("Add D4…")
    @remove = UIng::Button.new("Remove")
    @up = UIng::Button.new("Up")
    @down = UIng::Button.new("Down")
    @show = UIng::Checkbox.new("Show")
    @shared_y = UIng::Checkbox.new("Shared Y")
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
    @file_label = UIng::Label.new("No D4 file open")
    @track_combo = UIng::Combobox.new
    @chromosome_combo = UIng::Combobox.new
    @region_entry = UIng::Entry.new
    @go = UIng::Button.new("Go")
    @tools = Toolbar.new
    @details = UIng::Box.new(:vertical)
    @details_toggle = UIng::Button.new("Show details")
    @details_visible = false
    @progress = UIng::ProgressBar.new
    @annotation_label = UIng::Label.new("")
    @remove_annotation = UIng::Button.new("Remove")
    @status = UIng::Label.new("Open a D4 file to begin. Coordinates are 1-based, inclusive.")
    @inspection = UIng::Label.new("Move the pointer over the signal to inspect a bin.")

    def self.create_menu_bar
      file = UIng::Menu.new("File")
      open = file.append_item("Open D4…")
      create = file.append_item("Create D4 from BAM / CRAM…")
      export = file.append_item("Export selected track bins…")
      settings = file.append_preferences_item
      file.append_quit_item
      help = UIng::Menu.new("Help")
      guide = help.append_item("Navigation and data interpretation")
      about = help.append_about_item
      {open: open, create: create, export: export, settings: settings, guide: guide, about: about}
    end

    def initialize(menu_items)
      @window = UIng::Window.new(PROGRAM_NAME, 1120, 780, menubar: true, margined: true)
      @area = UIng::Area.new(@handler, @canvas_width, 400)
      setup_ui
      setup_handlers
      @window.on_content_size_changed { |_, _| resize_canvas }
      menu_items[:open].on_clicked { open_file_dialog }
      menu_items[:create].on_clicked { open_conversion }
      menu_items[:export].on_clicked { export_view }
      menu_items[:settings].on_clicked { open_settings }
      menu_items[:guide].on_clicked { show_help }
      menu_items[:about].on_clicked { @window.msg_box(PROGRAM_NAME, "D4 genomic signal viewer\nhttps://github.com/kojix2/d4.cr") }
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
      paths.each_with_index { |path, index| load_d4_file(path, append: index > 0) }
      if region && !@layers.empty?
        @region_entry.text = region
        go_to_entry
      end
      # Advance both event loops: tabix pipe readers and child-process
      # notifications need Crystal's scheduler as well as the native UI loop.
      UIng.main_steps
      while UIng.main_step(false)
        sleep 8.milliseconds
      end
    ensure
      shutdown
      # Complete all native UI teardown before yielding to worker joins.
      UIng.uninit
      @loader.wait
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
      files = row
      @track_combo.set_minimum_size(0, -1)
      files.append(@file_label, false)
      files.append(@track_combo, true)
      files.append(@show, false)
      files.append(@up, false)
      files.append(@down, false)
      files.append(@remove, false)
      files.append(@add, false)
      files.append(@details_toggle, false)
      root.append(files, false)

      location = row
      location.append(UIng::Label.new("Chromosome"), false)
      location.append(@chromosome_combo, false)
      location.append(UIng::Label.new("Region (1-based)"), false)
      location.append(@region_entry, true)
      location.append(@go, false)
      location.append(@shared_y, false)
      location.append(UIng::Label.new("Height"), false)
      ["Compact", "Normal", "Large"].each { |name| @height.append(name) }
      @height.selected = 1
      location.append(@height, false)
      root.append(location, false)

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
      @welcome.append(UIng::Box.new(:vertical), true)
      @welcome.append(UIng::Label.new("View genomic coverage"), false)
      @welcome.append(UIng::Label.new("Open an existing D4, or create one from an indexed BAM / CRAM."), false)
      welcome_buttons = row
      open = UIng::Button.new("Open D4…")
      create = UIng::Button.new("Create D4…")
      open.on_clicked { open_file_dialog }
      create.on_clicked { open_conversion }
      welcome_buttons.append(open, false)
      welcome_buttons.append(create, false)
      @welcome.append(welcome_buttons, false)
      @welcome.append(UIng::Box.new(:vertical), true)
      root.append(@welcome, true)
      root.append(@area, true)
      root.append(@inspection, false)
      status = row
      @status.set_minimum_size(0, -1)
      @inspection.set_minimum_size(0, -1)
      status.append(@status, true)
      status.append(@progress, false)
      status.append(@conversion_status, false)
      @conversion_status.hide
      root.append(status, false)
      @progress.value = -1
      @progress.hide
      @window.toolbar = @tools.native
      @window.child = root
    end

    private def setup_handlers
      @details_toggle.on_clicked do
        @details_visible = !@details_visible
        @details_visible ? @details.show : @details.hide
        @details_toggle.text = @details_visible ? "Hide details" : "Show details"
      end
      @tools.open.on_clicked { open_file_dialog }
      @tools.create.on_clicked { open_conversion }
      @conversion_status.on_clicked { open_conversion }
      @tools.annotations.on_clicked { open_annotation_dialog }
      @tools.settings.on_clicked { open_settings }
      @go.on_clicked { go_to_entry }
      @chromosome_combo.on_selected { |index| select_chromosome(index) unless @updating }
      @track_combo.on_selected { |index| select_layer(index) unless @updating }
      @add.on_clicked { open_file_dialog(true) }
      @remove.on_clicked { remove_layer }
      @up.on_clicked { reorder_layer(-1) }
      @down.on_clicked { reorder_layer(1) }
      @show.on_toggled do
        unless @updating
          if layer = selected_layer
            layer.visible = @show.checked?
            clear_drag
            resize_canvas
            refresh
          end
        end
      end
      @shared_y.on_toggled { @area.queue_redraw_all }
      @height.on_selected do |index|
        @row_height = {160.0, 220.0, 300.0}[index]
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
      @tools.export.on_clicked { export_view }
      @remove_annotation.on_clicked do
        @annotation_path = nil
        @pending_annotation_path = nil
        @annotation = nil
        @annotation_row.hide
        refresh
      end
      @handler.draw do |_, params|
        @renderer.draw(params, visible_layers, @completed_region, @settings, @chromosomes, @annotation, @loading,
          stack_geometry, @shared_y.checked?, selected_layer.try(&.source.key))
      end
      @handler.mouse_event { |_, event| mouse_event(event) }
      @handler.mouse_crossed do |_, left|
        if left
          @renderer.hover_index = nil
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
      @canvas_width = Math.max(@window.content_size[0] - 64, 240)
      @area.set_size(@canvas_width, stack_geometry.height(AnnotationRenderer.height_for(@annotation)))
      @area.queue_redraw_all
    end

    private def open_file_dialog(append : Bool = false)
      if path = @window.open_file
        load_d4_file(path, append: append)
      end
    end

    private def load_d4_file(path : String, region_text : String? = nil, append : Bool = false) : Bool
      sources = TrackSource.load(path)
      candidates = append ? @layers.dup : [] of TrackLayer
      sources.each do |source|
        candidates << TrackLayer.new(source) unless candidates.any? { |layer| layer.source.key == source.key }
      end
      # Validate the complete candidate set before replacing the workspace.
      TrackSource.chromosomes(candidates.map(&.source))
      cancel_loading
      @layers = candidates
      unless append
        @history.clear
        @completed_region = nil
        @annotation = nil
        @annotation_path = nil
        @annotation_row.hide
        @selected = 0
        @area.scroll_to(0, 0, 1, 1)
      end
      rebuild_layers(region_text)
      true
    rescue ex
      @updating = false
      show_error("Could not open D4 file", ex)
      false
    end

    private def rebuild_layers(region_text : String? = nil)
      previous = active_region
      @chromosomes = TrackSource.chromosomes(@layers.map(&.source))
      @chromosome_names = @chromosomes.keys
      @history.retain(@chromosomes)
      @selected = @selected.clamp(0, Math.max(@layers.size - 1, 0))
      @updating = true
      @track_combo.clear
      @layers.each_with_index { |layer, i| @track_combo.append("#{i + 1}. #{layer.source.label}") }
      @track_combo.selected = @layers.empty? ? nil : @selected
      @chromosome_combo.clear
      @chromosome_names.each { |name| @chromosome_combo.append(name) }
      @updating = false
      @file_label.text = "Tracks (#{@layers.size})"
      @window.title = "#{PROGRAM_NAME} — #{@layers.size} tracks"
      select_layer(@selected, false)
      if @layers.empty?
        @completed_region = nil
        @annotation = nil
        @annotation_path = nil
        @annotation_row.hide
        @region_entry.text = ""
        @source_entry.text = ""
        @status.text = "Open or add a D4 file to begin."
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
      @track_combo.selected = index
      @show.checked = layer.visible?
      @source_entry.text = "#{layer.source.path} | track: #{layer.source.name.empty? ? "Default" : layer.source.name} | D4 denominator: #{layer.source.denominator}"
      @updating = false
      if scroll && (visible_index = visible_layers.index(layer))
        @area.scroll_to(0, stack_geometry.row_top(visible_index), 1, @row_height)
      end
      update_controls
      @area.queue_redraw_all
    end

    private def remove_layer
      return unless selected_layer
      cancel_loading
      @layers.delete_at(@selected)
      rebuild_layers
    end

    private def reorder_layer(delta : Int32)
      target = @selected + delta
      return unless 0 <= target < @layers.size
      # Ordering does not affect data identity or require a new read.
      @layers.swap(@selected, target)
      @selected = target
      @updating = true
      @track_combo.clear
      @layers.each_with_index { |layer, i| @track_combo.append("#{i + 1}. #{layer.source.label}") }
      @updating = false
      select_layer(target)
    end

    private def select_chromosome(index : Int32)
      return unless name = @chromosome_names[index]?
      request_view(Region.new(name, 1_u32, @chromosomes[name]))
    end

    private def go_to_entry
      request_view(Region.resolve(@region_entry.text || "", @chromosomes))
    rescue ex
      show_error("Check region", ex)
    end

    private def request_view(region : Region, history_move : Int32 = 0)
      return if @layers.empty?
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
      @status.text = "Loading #{region}…"
      @inspection.text = "Loading requested region; the plot retains the previous completed view."
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
        @status.text = "Read failed: #{error}"
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
          @annotation_label.text = "Annotation could not be loaded. #{@annotation_path ? "Previous selection kept." : "No annotation selected."}"
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
        @status.text = "#{DisplayFormat.position(result.request.region.length)} bp | #{result.layers.size} visible tracks | #{failed} unavailable | #{result.elapsed_ms.round(1)} ms"
        @inspection.text = "Hover to inspect a track; drag to pan all tracks. Bins show means."
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
      return if @loading
      if region = @history.back
        request_view(region, -1)
      end
    end

    private def history_forward
      return if @loading
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
      @status.text = "Loading cancelled; previous view retained." if was_loading
      update_controls
      @area.queue_redraw_all
    end

    private def restore_location
      if region = @completed_region
        @region_entry.text = region.to_s
        @inspection.text = "Hover to inspect a track; drag to pan all tracks. Bins show means."
        @updating = true
        @chromosome_combo.selected = @chromosome_names.index(region.chromosome)
        @updating = false
      end
    end

    private def open_annotation_dialog
      return if @layers.empty?
      if path = @window.open_file
        @pending_annotation_path = path
        @annotation_label.text = "Loading annotation: #{short_name(path)}…"
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
        window = SettingsWindow.new(@settings, @window, ->(reload_data : Bool) {
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
      return if @loading || !layer.visible? || view.region != @completed_region
      if path = @window.save_file
        (@layers.map(&.source.path) + [@annotation_path].compact).each do |source|
          if File.expand_path(path) == File.expand_path(source) || (File.exists?(path) && File.same?(path, source))
            raise "Choose a different path from the input D4 or annotation file."
          end
        end
        File.open(path, "w") do |io|
          io << "# Source: " << layer.source.path.gsub(/[\r\n]/, " ") << "; track: " << layer.source.name.gsub(/[\r\n]/, " ") << '\n'
          view.write_bedgraph(io)
        end
        @status.text = "Exported #{view.points.size} bin means to #{File.basename(path)} (bedGraph, 0-based half-open)."
      end
    rescue ex
      show_error("Could not export bins", ex)
    end

    private def update_controls
      if @layers.empty?
        @welcome.show
        @area.hide
        @inspection.hide
      else
        @welcome.hide
        @area.show
        @inspection.show
      end
      @loading ? @progress.show : @progress.hide
      update_region_controls
      update_layer_controls
      update_history_controls
      @annotation_row.visible? ? @remove_annotation.enable : @remove_annotation.disable
      @remove_annotation.text = @annotation_path || @pending_annotation_path ? "Remove" : "Dismiss"
    end

    private def update_region_controls
      ready = !@layers.empty? && !@chromosomes.empty?
      [@go, @chromosome_combo, @region_entry].each do |control|
        ready ? control.enable : control.disable
      end
      [@tools.annotations, @tools.left, @tools.right, @tools.zoom_in, @tools.zoom_out, @tools.whole].each do |control|
        ready ? control.enable : control.disable
      end
      @loading ? @tools.cancel.enable : @tools.cancel.disable
    end

    private def update_layer_controls
      @layers.size > 1 ? @track_combo.enable : @track_combo.disable
      [@remove, @show].each do |control|
        @layers.empty? ? control.disable : control.enable
      end
      @selected > 0 ? @up.enable : @up.disable
      @selected < @layers.size - 1 ? @down.enable : @down.disable
      layer = selected_layer
      exportable = layer && layer.visible? && layer.view.try(&.region) == @completed_region && !layer.view.nil? && !@loading
      exportable ? @tools.export.enable : @tools.export.disable
    end

    private def update_history_controls
      @history.back? && !@loading ? @tools.back.enable : @tools.back.disable
      @history.forward? && !@loading ? @tools.forward.enable : @tools.forward.disable
    end

    private def mouse_event(event)
      return unless region = @completed_region
      return if @loading
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
      @inspection.text = "#{layer.source.label} | #{view.inspect_bin(bin)}"
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
        @inspection.text = "Release to select this range in all tracks. Esc to cancel."
      else
        preview = drag[1].pan(drag[0] - fraction, @chromosomes[drag[1].chromosome])
        @renderer.preview_region = preview
        @inspection.text = "Preview: #{preview}. Gray areas are unread. Release to load all tracks; Esc to cancel."
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
      @inspection.text = "Hover to inspect a track; drag to pan all tracks. Bins show means."
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
      @window.msg_box("Using D4 Plot", "Open a D4 file to show all its tracks. Add D4 appends another file. Select a track using its title or the list; Show, Up, Down and Remove manage it. Shared Y compares visible tracks on one scale. All files must use the same reference assembly.\nEnter chr:start-end, chr:position, or a chromosome name, then click Go. Commas in coordinates are accepted.\n\nCoordinates in the viewer are 1-based and inclusive. The signal shows the mean in each bin, with the D4 denominator applied. Zoom in to resolve narrow peaks; a flat bin can contain variation.\n\nDrag to pan; Shift+drag to select a range; double-click to zoom in; right-click to zoom out. Click the chromosome overview to jump. Back and Forward restore visited regions. Keyboard navigation works when the plot has focus.\n\nDisplay settings control resolution, color and fixed Y scale for all tracks. Height controls the track rows. The native scrollbar moves vertically. Use a fixed Y scale when comparing regions. D4 does not identify the reference assembly here: annotations must use the same assembly and exact chromosome names.\n\nExport bins writes the selected visible track’s means as bedGraph (0-based, half-open), not the original per-base signal.")
    end

    private def short_name(path)
      name = File.basename(path)
      name.size > 64 ? "#{name[0, 40]}…#{name[-20, 20]}" : name
    end

    private def update_annotation_label
      if path = @annotation_path
        @annotation_label.text = "Annotation: #{short_name(path)} · verify the reference assembly"
        @annotation_label.tooltip = path
        @annotation_row.show
      else
        @annotation_row.hide
      end
    end

    private def open_conversion
      window = @conversion_window ||= ConversionWindow.new(@conversion_worker, ->(path : String) { load_d4_file(path, append: true) })
      window.show
    end

    private def poll_conversion
      @conversion_window.try(&.poll)
      state = @conversion_worker.snapshot.state
      unless state.idle?
        @conversion_status.show
        @conversion_status.text = case state
                                  when .running?    then "Creating D4…"
                                  when .cancelling? then "Cancelling D4…"
                                  when .succeeded?  then "D4 ready — review…"
                                  when .cancelled?  then "D4 cancelled…"
                                  else                   "D4 creation failed…"
                                  end
      else
        @conversion_status.hide
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
      window = UIng::Window.new("D4 creation is running", 440, 150, margined: true)
      root = UIng::Box.new(:vertical, padded: true)
      message = UIng::Label.new("Quit will cancel D4 creation. No unfinished file will be kept.")
      root.append(message, true)
      buttons = row
      keep = UIng::Button.new("Keep working")
      quit = UIng::Button.new("Cancel creation and quit")
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
        message.text = "Stopping safely before quitting. Finalizing the index may take time."
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
      @status.text = message
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
      @window.toolbar = nil
      @tools.free
    end
  end
end
