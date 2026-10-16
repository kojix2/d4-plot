require "uing"
require "./i18n"
require "./annotation_renderer"
require "./plot_settings"
require "./plot_geometry"
require "./track_layer"

module D4Plot
  class PlotRenderer
    property hover_layer : Tuple(String, String)? = nil
    property hover_index : Int32? = nil
    property selection : Tuple(Float64, Float64)? = nil
    property preview_region : Region? = nil
    property overview_preview_region : Region? = nil

    def initialize
      @annotation_renderer = AnnotationRenderer.new
      @label_fonts = {} of Float64 => UIng::FontDescriptor
    end

    def draw(params, layers : Array(TrackLayer), completed_region : Region?, settings : PlotSettings,
             chromosomes : Hash(String, UInt32), annotation_track : AnnotationTrack?, loading : Bool,
             stack : StackGeometry, shared_y : Bool, selected : Tuple(String, String)?)
      ctx = params.context
      ctx.fill_path(brush(1.0, 1.0, 1.0)) do |path|
        path.add_rectangle(params.clip_x, params.clip_y, params.clip_width, params.clip_height)
      end
      region = @preview_region || completed_region
      unless region
        label(ctx, loading ? D4Plot.t("plot.loading_tracks") : D4Plot.t("plot.empty"), 20.0, 90.0, stack.width - 40, :center, 17.0)
        return
      end
      layout = stack.plot(0)
      label(ctx, D4Plot.t("plot.region_header", chromosome: region.chromosome,
        start: DisplayFormat.position(region.start1), end: DisplayFormat.position(region.end1),
        bases: DisplayFormat.position(region.length)), layout.left, 8.0, layout.width, :left, 13.0)
      draw_overview(ctx, layout, @overview_preview_region || region, chromosomes)
      shared_range = shared_range_for(layers, completed_region, settings, shared_y)
      layers.each_with_index do |layer, index|
        next unless stack.visible?(index, params.clip_y, params.clip_height)
        draw_layer(ctx, layer, index, stack, region, completed_region, settings, shared_range, shared_y, selected)
      end
      if layers.empty?
        label(ctx, D4Plot.t("plot.all_hidden"), layout.left, 110.0, layout.width, :center)
      end
      annotation_height = AnnotationRenderer.height_for(annotation_track)
      @annotation_renderer.draw(ctx, annotation_track, region, layout.left, stack.annotation_top, layout.width, annotation_height)
    end

    private def shared_range_for(layers, completed_region, settings, shared_y)
      return unless shared_y
      views = layers.compact_map(&.view).select { |view| view.region == completed_region }
      return if views.empty?
      settings.y_range(views.min_of(&.minimum), views.max_of(&.maximum))
    end

    private def draw_layer(ctx, layer, index, stack, region, completed_region, settings, shared_range, shared_y, selected)
      row = stack.plot(index)
      top = stack.row_top(index)
      if layer.source.key == selected
        ctx.fill_path(brush(0.94, 0.96, 0.97)) { |path| path.add_rectangle(0, top, stack.width, 27) }
        ctx.fill_path(brush(0.16, 0.42, 0.58)) { |path| path.add_rectangle(2, top, 3, 27) }
      end
      max_chars = Math.max((row.width / 8).to_i, 12)
      title = "#{index + 1}. #{layer.source.label}"
      title = title[0, max_chars - 1] + "…" if title.size > max_chars
      label(ctx, title, row.left, top + 5, row.width, :left, 12.0)
      view = layer.view
      if view && view.region == completed_region
        draw_signal_row(ctx, layer, view, row, region, settings, shared_range, shared_y)
      else
        label(ctx, layer.error || D4Plot.t("plot.waiting"), row.left, row.top + 20, row.width, :center)
      end
      draw_ticks(ctx, row, region) if settings.show_axis_ticks?
    end

    private def draw_signal_row(ctx, layer, view, row, region, settings, shared_range, shared_y)
      range = shared_range || settings.y_range(view.minimum, view.maximum)
      draw_grid(ctx, row, range)
      ctx.save
      ctx.clip_path { |path| path.add_rectangle(row.left, row.top, row.width, row.height) }
      draw_bins(ctx, view, region, row, range, settings)
      draw_unread(ctx, view.region, region, row) if @preview_region
      draw_reference_lines(ctx, row, range, settings)
      draw_inspection(ctx, view, row, layer.source.key == @hover_layer)
      ctx.restore
      scale = settings.y_min ? D4Plot.t("plot.fixed_y") : shared_y ? D4Plot.t("app.shared_y") : D4Plot.t("plot.auto_y")
      mean_label = @preview_region ? D4Plot.t("plot.loaded_mean") : D4Plot.t("plot.mean")
      label(ctx, D4Plot.t("plot.summary", mean: mean_label, value: DisplayFormat.value(view.mean), resolution: view.resolution, scale: scale), row.left, row.top + row.height + 30, row.width, :right)
    end

    private def draw_overview(ctx, layout, region, chromosomes)
      return unless size = chromosomes[region.chromosome]?
      return if size == 0
      y = PlotGeometry::OVERVIEW_BAR_TOP
      ctx.fill_path(brush(0.89, 0.91, 0.94)) do |path|
        add_rounded_rectangle(path, layout.left, y, layout.width, PlotGeometry::OVERVIEW_BAR_HEIGHT, 5.0)
      end
      x, width = layout.overview_viewport(region, size)
      ctx.fill_path(brush(0.12, 0.4, 0.68, 0.8)) do |path|
        path.add_rectangle(x, PlotGeometry::OVERVIEW_WINDOW_TOP, width, PlotGeometry::OVERVIEW_WINDOW_HEIGHT)
      end
      label(ctx, D4Plot.t("plot.bases", number: "1"), layout.left, y + 18, 80.0)
      label(ctx, D4Plot.t("plot.bases", number: DisplayFormat.position(size)), layout.left + layout.width - 130, y + 18, 130.0, :right)
    end

    private def add_rounded_rectangle(path : UIng::Area::Draw::Path, x : Float64, y : Float64, width : Float64, height : Float64, radius : Float64)
      radius = Math.min(radius, Math.min(width, height) / 2.0)
      path.new_figure(x + radius, y)
      path.line_to(x + width - radius, y)
      path.arc_to(x + width - radius, y + radius, radius, Math::PI * 1.5, Math::PI / 2.0, false)
      path.line_to(x + width, y + height - radius)
      path.arc_to(x + width - radius, y + height - radius, radius, 0.0, Math::PI / 2.0, false)
      path.line_to(x + radius, y + height)
      path.arc_to(x + radius, y + height - radius, radius, Math::PI / 2.0, Math::PI / 2.0, false)
      path.line_to(x, y + radius)
      path.arc_to(x + radius, y + radius, radius, Math::PI, Math::PI / 2.0, false)
      path.close_figure
    end

    private def draw_grid(ctx, layout, range)
      low, high = range
      5.times do |index|
        value = low + (high - low) * (index / 4.0)
        y = y_for(value, layout, range)
        ctx.stroke_path(brush(0.88, 0.9, 0.92), thickness: 1.0) do |path|
          path.new_figure(layout.left, y)
          path.line_to(layout.left + layout.width, y)
        end
        label(ctx, "%.3g" % value, 2.0, y - 8, layout.left - 12, :right)
      end
    end

    private def draw_bins(ctx, view, region, layout, range, settings)
      red, green, blue, alpha = settings.plot_color
      baseline = y_for(0.0.clamp(range[0], range[1]), layout, range)
      ctx.fill_path(brush(red, green, blue, alpha * 0.25)) do |path|
        path.new_figure(layout.x_for(view.region.start0.to_i64, region), baseline)
        view.points.each_with_index do |point, index|
          left, right = view.bin_edges(index)
          y = y_for(point[1], layout, range)
          path.line_to(layout.x_for(left, region), y)
          path.line_to(layout.x_for(right, region), y)
        end
        path.line_to(layout.x_for(view.region.end0_exclusive.to_i64, region), baseline)
        path.close_figure
      end
      ctx.stroke_path(brush(red, green, blue, alpha), thickness: 1.5) do |path|
        path.new_figure(layout.x_for(view.region.start0.to_i64, region), y_for(view.points.first[1], layout, range))
        view.points.each_with_index do |point, index|
          left, right = view.bin_edges(index)
          y = y_for(point[1], layout, range)
          path.line_to(layout.x_for(left, region), y)
          path.line_to(layout.x_for(right, region), y)
        end
      end
    end

    private def draw_unread(ctx, loaded, region, layout)
      # Mark only the uncovered part, rather than drawing fabricated zero bins.
      left = layout.x_for(loaded.start0.to_i64, region).clamp(layout.left, layout.left + layout.width)
      right = layout.x_for(loaded.end0_exclusive.to_i64, region).clamp(layout.left, layout.left + layout.width)
      ctx.fill_path(brush(0.88, 0.89, 0.90)) do |path|
        path.add_rectangle(layout.left, layout.top, left - layout.left, layout.height)
        path.add_rectangle(right, layout.top, layout.left + layout.width - right, layout.height)
      end
    end

    private def draw_reference_lines(ctx, layout, range, settings)
      settings.h_lines.each do |value|
        next unless range[0] <= value <= range[1]
        y = y_for(value, layout, range)
        ctx.stroke_path(brush(0.75, 0.3, 0.12), thickness: 1.0) do |path|
          path.new_figure(layout.left, y)
          path.line_to(layout.left + layout.width, y)
        end
        label(ctx, DisplayFormat.value(value), layout.left + layout.width - 80, y - 18, 75.0, :right)
      end
    end

    private def draw_inspection(ctx, view, layout, hovered : Bool)
      if index = @hover_index
        if hovered && 0 <= index < view.points.size
          left, right = view.bin_edges(index)
          x = layout.x_for(left, view.region)
          width = Math.max(layout.x_for(right, view.region) - x, 1.0)
          ctx.fill_path(brush(0.2, 0.4, 0.6, 0.12)) { |path| path.add_rectangle(x, layout.top, width, layout.height) }
        end
      end
      if selection = @selection
        left, right = selection.minmax
        ctx.fill_path(brush(0.1, 0.5, 0.7, 0.2)) do |path|
          path.add_rectangle(layout.left + left * layout.width, layout.top, (right - left) * layout.width, layout.height)
        end
      end
    end

    private def draw_ticks(ctx, layout, region)
      count = Math.min(5, region.length.to_i64).to_i
      positions = Array.new(count) do |index|
        region.start1.to_i64 + (count == 1 ? 0_i64 : (region.length.to_i64 - 1) * index // (count - 1))
      end
      positions.each do |position|
        x = layout.left + (position - region.start0 - 0.5) / region.length * layout.width
        ctx.stroke_path(brush(0.52, 0.56, 0.60), thickness: 1.0) do |path|
          path.new_figure(x, layout.top + layout.height)
          path.line_to(x, layout.top + layout.height + 4.0)
        end
        label(ctx, DisplayFormat.position(position), x - 60, layout.top + layout.height + 8, 120.0, :center)
      end
    end

    private def y_for(value, layout, range)
      layout.top + layout.height * (1.0 - (value - range[0]) / (range[1] - range[0]))
    end

    private def brush(red, green, blue, alpha = 1.0)
      UIng::Area::Draw::Brush.new(:solid, red, green, blue, alpha)
    end

    private def label(ctx, text, x, y, width, align = :left, size = 11.0)
      UIng::Area::AttributedString.open(text) do |string|
        string.set_attribute(UIng::Area::Attribute.new_color(0.18, 0.22, 0.28, 1.0), 0_u64, text.bytesize.to_u64)
        alignment = case align
                    when :center then UIng::Area::Draw::TextAlign::Center
                    when :right  then UIng::Area::Draw::TextAlign::Right
                    else              UIng::Area::Draw::TextAlign::Left
                    end
        font = @label_fonts[size] ||= UIng::FontDescriptor.new(size: size)
        UIng::Area::Draw::TextLayout.open(string: string, default_font: font, width: width, align: alignment) do |layout|
          ctx.draw_text_layout(layout, x, y)
        end
      end
    end
  end
end
