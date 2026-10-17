require "./annotation_renderer"
require "./plot_geometry"
require "./plot_settings"
require "./track_layer"

module D4Plot
  # Renders the complete scrolling plot from the same sampled views and layout
  # used by Area. Build on the UI thread so a later navigation cannot change
  # the image while BackgroundIO writes it.
  class SvgExport
    getter path : String
    @height : Int32
    @contents : String

    def self.destination(chosen_path : String) : String
      return chosen_path if chosen_path.downcase.ends_with?(".svg")
      path = "#{chosen_path}.svg"
      raise D4Plot.t("app.image_exists", name: File.basename(path)) if File.exists?(path)
      path
    end

    def initialize(@path : String, @sources : Array(String), @region : Region,
                   @layers : Array(TrackLayer), @annotation : AnnotationTrack?,
                   @settings : PlotSettings, @chromosome_size : UInt32?,
                   @width : Int32, @row_height : Float64, @shared_y : Bool,
                   @selected : Tuple(String, String)?)
      @stack = StackGeometry.new(@width.to_f64, @row_height, @layers.size)
      @height = @stack.height(AnnotationRenderer.height_for(@annotation))
      @contents = String.build { |io| render(io) }
    end

    def write : Nil
      destination = File.expand_path(@path)
      @sources.each do |source|
        if destination == File.expand_path(source) || same_existing_file?(destination, source)
          raise D4Plot.t("app.export_conflict")
        end
      end
      write_atomically(destination)
    end

    private def same_existing_file?(first : String, second : String) : Bool
      return false unless File.exists?(first) && File.exists?(second)
      File.same?(first, second)
    rescue File::NotFoundError
      false
    end

    # Staging beside the destination keeps rename atomic. In particular, a
    # source hard link introduced after the checks above is replaced rather
    # than truncated by an in-place write.
    private def write_atomically(destination : String) : Nil
      File.tempfile(".d4-plot-svg-", ".tmp", dir: File.dirname(destination)) do |file|
        begin
          file.print(@contents)
          file.close
          File.rename(file.path, destination)
        ensure
          file.close unless file.closed?
          File.delete?(file.path)
        end
      end
    end

    private def render(io : IO) : Nil
      io << %(<?xml version="1.0" encoding="UTF-8"?>\n)
      io << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}" viewBox="0 0 #{@width} #{@height}">\n)
      io << %(<rect width="100%" height="100%" fill="white"/>\n)
      layout = @stack.plot(0)
      label(io, D4Plot.t("plot.region_header", chromosome: @region.chromosome,
        start: DisplayFormat.position(@region.start1), end: DisplayFormat.position(@region.end1),
        bases: DisplayFormat.position(@region.length)), layout.left, 8.0, layout.width, size: 13)
      draw_overview(io, layout)
      shared_range = shared_range_for
      @layers.each_with_index do |layer, index|
        draw_layer(io, layer, index, shared_range)
      end
      label(io, D4Plot.t("plot.all_hidden"), layout.left, 110.0, layout.width, :center) if @layers.empty?
      draw_annotation(io, layout)
      io << "</svg>\n"
    end

    private def draw_overview(io : IO, layout : PlotGeometry) : Nil
      size = @chromosome_size
      return unless size && size > 0
      y = PlotGeometry::OVERVIEW_BAR_TOP
      rect(io, layout.left, y, layout.width, PlotGeometry::OVERVIEW_BAR_HEIGHT, "#e3e8f0", radius: 5.0)
      x, width = layout.overview_viewport(@region, size)
      rect(io, x, PlotGeometry::OVERVIEW_WINDOW_TOP, width, PlotGeometry::OVERVIEW_WINDOW_HEIGHT, "#1f66ad", opacity: 0.8)
      label(io, D4Plot.t("plot.bases", number: "1"), layout.left, y + 18, 80.0)
      label(io, D4Plot.t("plot.bases", number: DisplayFormat.position(size)), layout.left + layout.width - 130, y + 18, 130.0, :right)
    end

    private def shared_range_for : Tuple(Float64, Float64)?
      return unless @shared_y
      views = @layers.compact_map(&.view).select { |view| view.region == @region }
      return if views.empty?
      @settings.y_range(views.min_of(&.minimum), views.max_of(&.maximum))
    end

    private def draw_layer(io : IO, layer : TrackLayer, index : Int32,
                           shared_range : Tuple(Float64, Float64)?) : Nil
      layout = @stack.plot(index)
      top = @stack.row_top(index)
      if layer.source.key == @selected
        rect(io, 0.0, top, @stack.width, 27.0, "#f0f5f7")
        rect(io, 2.0, top, 3.0, 27.0, "#296b94")
      end
      max_chars = Math.max((layout.width / 8).to_i, 12)
      title = "#{index + 1}. #{layer.source.label}"
      title = title[0, max_chars - 1] + "…" if title.size > max_chars
      label(io, title, layout.left, top + 5, layout.width, size: 12)

      if (view = layer.view) && view.region == @region
        draw_signal_row(io, view, layout, shared_range)
      else
        label(io, layer.error || D4Plot.t("plot.waiting"), layout.left, layout.top + 20, layout.width, :center)
      end
      draw_ticks(io, layout) if @settings.show_axis_ticks?
    end

    private def draw_signal_row(io : IO, view : SampledView, layout : PlotGeometry,
                                shared_range : Tuple(Float64, Float64)?) : Nil
      range = shared_range || @settings.y_range(view.minimum, view.maximum)
      draw_grid(io, layout, range)
      clip_id = "plot-#{layout.top.to_i}"
      clip(io, clip_id, layout.left, layout.top, layout.width, layout.height)
      io << %(<g clip-path="url(##{clip_id})">\n)
      red, green, blue, alpha = @settings.plot_color
      color = rgb(red, green, blue)
      io << %(<path d="#{signal_path(view, layout, range, true)}" fill="#{color}" fill-opacity="#{num(alpha * 0.25)}"/>\n)
      io << %(<path d="#{signal_path(view, layout, range, false)}" fill="none" stroke="#{color}" stroke-opacity="#{num(alpha)}" stroke-width="1.5"/>\n)
      @settings.h_lines.each do |value|
        next unless range[0] <= value <= range[1]
        line(io, layout.left, y_for(value, layout, range), layout.left + layout.width,
          y_for(value, layout, range), "#bf4d1f")
      end
      io << "</g>\n"
      @settings.h_lines.each do |value|
        next unless range[0] <= value <= range[1]
        label(io, DisplayFormat.value(value), layout.left + layout.width - 80,
          y_for(value, layout, range) - 18, 75.0, :right)
      end
      scale = @settings.y_min ? D4Plot.t("plot.fixed_y") : @shared_y ? D4Plot.t("app.shared_y") : D4Plot.t("plot.auto_y")
      label(io, D4Plot.t("plot.summary", mean: D4Plot.t("plot.mean"), value: DisplayFormat.value(view.mean),
        resolution: view.resolution, scale: scale), layout.left, layout.top + layout.height + 30, layout.width, :right)
    end

    private def signal_path(view : SampledView, layout : PlotGeometry,
                            range : Tuple(Float64, Float64), filled : Bool) : String
      String.build do |path|
        start_x = layout.x_for(view.region.start0.to_i64, @region)
        start_y = filled ? y_for(0.0.clamp(range[0], range[1]), layout, range) : y_for(view.points.first[1], layout, range)
        path << "M" << num(start_x) << " " << num(start_y)
        view.points.each_with_index do |point, index|
          left, right = view.bin_edges(index)
          y = y_for(point[1], layout, range)
          path << " L" << num(layout.x_for(left, @region)) << " " << num(y)
          path << " L" << num(layout.x_for(right, @region)) << " " << num(y)
        end
        if filled
          path << " L" << num(layout.x_for(view.region.end0_exclusive.to_i64, @region)) << " " << num(start_y) << " Z"
        end
      end
    end

    private def draw_grid(io : IO, layout : PlotGeometry, range : Tuple(Float64, Float64)) : Nil
      low, high = range
      5.times do |index|
        value = PlotSettings.interpolate(low, high, index / 4.0)
        y = y_for(value, layout, range)
        line(io, layout.left, y, layout.left + layout.width, y, "#e0e5eb")
        label(io, "%.3g" % value, 2.0, y - 8, layout.left - 12, :right)
      end
    end

    private def draw_ticks(io : IO, layout : PlotGeometry) : Nil
      count = Math.min(5, @region.length.to_i64).to_i
      count.times do |index|
        position = @region.start1.to_i64 + (count == 1 ? 0_i64 : (@region.length.to_i64 - 1) * index // (count - 1))
        x = layout.left + (position - @region.start0 - 0.5) / @region.length * layout.width
        line(io, x, layout.top + layout.height, x, layout.top + layout.height + 4.0, "#858f99")
        label(io, DisplayFormat.position(position), x - 60, layout.top + layout.height + 8, 120.0, :center)
      end
    end

    private def draw_annotation(io : IO, layout : PlotGeometry) : Nil
      track = @annotation
      return unless track
      top = @stack.annotation_top
      line(io, layout.left, top, layout.left + layout.width, top, "#c7ccd1")
      if notice = track.notice
        label(io, notice, layout.left, top + 12, layout.width, :center, color: "#73787f")
        return
      end

      clip(io, "annotations", layout.left, top, layout.width, AnnotationRenderer::MAX_HEIGHT)
      io << %(<g clip-path="url(#annotations)">\n)
      lanes = AnnotationLaneAllocator.new((AnnotationRenderer::MAX_HEIGHT / AnnotationRenderer::LANE).floor.to_i - 1)
      hidden = 0
      track.features.sort_by { |feature| {feature.start1, feature.end1, feature.kind} }.each do |feature|
        if lane = lanes.assign(feature)
          draw_feature(io, feature, lane, layout, top)
        else
          hidden += 1
        end
      end
      io << "</g>\n"
      if hidden > 0
        label(io, D4Plot.t("plot.additional_features", number: hidden), layout.left,
          top + AnnotationRenderer::MAX_HEIGHT - 17, layout.width, :center, color: "#73787f")
      end
    end

    private def draw_feature(io : IO, feature : AnnotationFeature, lane : Int32,
                             layout : PlotGeometry, top : Float64) : Nil
      x1 = layout.x_for(feature.start1.to_i64 - 1, @region).clamp(layout.left, layout.left + layout.width)
      x2 = layout.x_for(feature.end1.to_i64, @region).clamp(layout.left, layout.left + layout.width)
      width = {x2 - x1, 1.0}.max
      y = top + 18.0 + lane * AnnotationRenderer::LANE
      if feature.kind == "exon"
        rect(io, x1, y - 4, width, 8.0, "#1f5c85", opacity: 0.9)
      else
        line(io, x1, y, x2, y, "#2e4757")
        if strand = feature.strand
          if (strand == "+" || strand == "-") && x2 - x1 > 12
            direction = strand == "+" ? 1.0 : -1.0
            tip = strand == "+" ? x2 - 2 : x1 + 2
            io << %(<path d="M#{num(tip - 4 * direction)} #{num(y - 3)} L#{num(tip)} #{num(y)} L#{num(tip - 4 * direction)} #{num(y + 3)}" fill="none" stroke="#2e4757"/>\n)
          end
        end
        if width > 34
          name = feature.name || feature.kind
          characters = Math.max((width / 8).floor.to_i, 2)
          name = name[0, characters - 1] + "…" if name.size > characters
          label(io, name, x1 + 3, y - 18, width - 6, color: "#262626")
        end
      end
    end

    private def y_for(value : Float64, layout : PlotGeometry, range : Tuple(Float64, Float64)) : Float64
      layout.top + layout.height * (1.0 - PlotSettings.normalized_position(value, range[0], range[1]))
    end

    private def rect(io : IO, x : Number, y : Number, width : Number, height : Number,
                     fill : String, opacity : Float64 = 1.0, radius : Float64 = 0.0) : Nil
      io << %(<rect x="#{num(x)}" y="#{num(y)}" width="#{num(width)}" height="#{num(height)}" fill="#{fill}" fill-opacity="#{num(opacity)}" rx="#{num(radius)}"/>\n)
    end

    private def line(io : IO, x1 : Number, y1 : Number, x2 : Number, y2 : Number, color : String) : Nil
      io << %(<line x1="#{num(x1)}" y1="#{num(y1)}" x2="#{num(x2)}" y2="#{num(y2)}" stroke="#{color}"/>\n)
    end

    private def clip(io : IO, id : String, x : Number, y : Number, width : Number, height : Number) : Nil
      io << %(<defs><clipPath id="#{id}"><rect x="#{num(x)}" y="#{num(y)}" width="#{num(width)}" height="#{num(height)}"/></clipPath></defs>\n)
    end

    private def label(io : IO, value : String, x : Number, y : Number, width : Number,
                      align : Symbol = :left, size : Int32 = 11, color : String = "#2e3947") : Nil
      text_x = case align
               when :center then x.to_f + width / 2
               when :right  then x.to_f + width
               else              x.to_f
               end
      anchor = align == :center ? "middle" : align == :right ? "end" : "start"
      io << %(<text x="#{num(text_x)}" y="#{num(y.to_f + size)}" fill="#{color}" font-family="sans-serif" font-size="#{size}" text-anchor="#{anchor}">)
      xml_text(io, value)
      io << "</text>\n"
    end

    private def xml_text(io : IO, value : String) : Nil
      value.each_char do |char|
        case char
        when '&'  then io << "&amp;"
        when '<'  then io << "&lt;"
        when '>'  then io << "&gt;"
        when '"'  then io << "&quot;"
        when '\'' then io << "&apos;"
        else
          codepoint = char.ord
          io << (codepoint < 32 && char != '\t' && char != '\n' && char != '\r' ? '�' : char)
        end
      end
    end

    private def rgb(red : Float64, green : Float64, blue : Float64) : String
      "rgb(#{(red * 255).round.to_i},#{(green * 255).round.to_i},#{(blue * 255).round.to_i})"
    end

    private def num(value : Number) : String
      "%.3f" % value.to_f
    end
  end
end
