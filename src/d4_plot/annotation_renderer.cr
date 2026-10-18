require "uing"
require "./i18n"
require "./annotation"
require "./public_genes"
require "./region"

module D4Plot
  class AnnotationLaneAllocator
    def initialize(@max_lanes : Int32)
      @lane_ends = [] of UInt32
    end

    def lane_count : Int32
      @lane_ends.size
    end

    def assign(feature : AnnotationFeature) : Int32?
      assign(feature.start1, feature.end1)
    end

    def assign(start1 : UInt32, end1 : UInt32) : Int32?
      @lane_ends.each_with_index do |lane_end, index|
        if start1 > lane_end
          @lane_ends[index] = end1
          return index
        end
      end

      return if @lane_ends.size >= @max_lanes

      @lane_ends << end1
      @lane_ends.size - 1
    end
  end

  class AnnotationRenderer
    GAP           =  14.0
    LANE          =  24.0
    MAX_HEIGHT    = 144.0
    HEADER_HEIGHT =  24.0

    def self.height_for(track : AnnotationTrack?)
      # Keep the annotation lane stable when panning through empty or dense areas.
      track.nil? ? 0.0 : MAX_HEIGHT
    end

    def draw(ctx, track : AnnotationTrack?, region : Region?, plot_left, top, plot_width, height,
             title : String? = nil)
      return unless track
      return if height <= 0 || plot_width <= 0

      draw_axis(ctx, plot_left, top, plot_width)
      draw_title(ctx, title, plot_left, top + 4.0, plot_width) if title
      if notice = track.notice
        draw_notice(ctx, notice, plot_left, top + HEADER_HEIGHT + 12.0, plot_width)
      elsif region
        ctx.save
        ctx.clip_path { |path| path.add_rectangle(plot_left, top, plot_width, height) }
        draw_features(ctx, track.features, region, plot_left, top + HEADER_HEIGHT, plot_width, height - HEADER_HEIGHT)
        ctx.restore
      end
    end

    def draw_genes(ctx, track : GeneTrack?, region : Region?, plot_left, top, plot_width, height, title : String)
      return unless track
      draw_axis(ctx, plot_left, top, plot_width)
      draw_title(ctx, title, plot_left, top + 4.0, plot_width)
      if notice = track.notice
        draw_notice(ctx, notice, plot_left, top + HEADER_HEIGHT + 12.0, plot_width)
      elsif region
        lanes = AnnotationLaneAllocator.new(((height - HEADER_HEIGHT) / LANE).floor.to_i - 1)
        hidden = 0
        ctx.save
        ctx.clip_path { |path| path.add_rectangle(plot_left, top, plot_width, height) }
        track.genes.sort_by { |gene| {gene.start1, gene.end1} }.each do |gene|
          if lane = lanes.assign(gene.start1, gene.end1)
            draw_gene(ctx, gene, lane, region, plot_left, top + HEADER_HEIGHT, plot_width)
          else
            hidden += 1
          end
        end
        ctx.restore
        if hidden > 0
          draw_notice(ctx, D4Plot.t("plot.additional_features", number: hidden), plot_left, top + height - 17, plot_width)
        end
      end
    end

    private def draw_gene(ctx, gene : GeneModel, lane : Int32, region : Region, plot_left, top, plot_width)
      x1 = plot_left + (gene.start1.to_i64 - 1 - region.start0).to_f / region.length * plot_width
      x2 = plot_left + (gene.end1.to_i64 - region.start0).to_f / region.length * plot_width
      x1 = x1.clamp(plot_left, plot_left + plot_width)
      x2 = x2.clamp(plot_left, plot_left + plot_width)
      y = top + 18.0 + lane * LANE
      draw_line(ctx, x1, x2, y, gene.strand)
      draw_label(ctx, gene.name, x1 + 3.0, y - 18.0, x2 - x1 - 6.0) if x2 - x1 > 34.0
      gene.exons.each do |(first, last)|
        left = (plot_left + (first.to_i64 - 1 - region.start0).to_f / region.length * plot_width).clamp(plot_left, plot_left + plot_width)
        right = (plot_left + (last.to_i64 - region.start0).to_f / region.length * plot_width).clamp(plot_left, plot_left + plot_width)
        draw_box(ctx, left, y - 4.0, Math.max(right - left, 1.0), 8.0, 0.12, 0.36, 0.52) if right > left
      end
    end

    private def draw_title(ctx, title, x, y, width)
      draw_label(ctx, title, x, y, width)
    end

    private def draw_axis(ctx, x, y, width)
      brush = UIng::Area::Draw::Brush.new(:solid, 0.78, 0.80, 0.82, 1.0)
      ctx.stroke_path(brush, thickness: 1.0) do |path|
        path.new_figure(x, y)
        path.line_to(x + width, y)
      end
    end

    private def draw_notice(ctx, text, x, y, width)
      UIng::Area::AttributedString.open(text) do |attr_str|
        attr_str.set_attribute(UIng::Area::Attribute.new_color(0.45, 0.47, 0.50, 1.0), 0_u64, text.bytesize.to_u64)

        UIng::Area::Draw::TextLayout.open(
          string: attr_str,
          default_font: label_font,
          width: width,
          align: UIng::Area::Draw::TextAlign::Center
        ) do |text_layout|
          ctx.draw_text_layout(text_layout, x, y)
        end
      end
    end

    private def draw_features(ctx, features, region, plot_left, top, plot_width, height)
      max_lanes = (height / LANE).floor.to_i - 1
      lanes = AnnotationLaneAllocator.new(max_lanes)
      hidden = 0

      features.sort_by { |feature| {feature.start1, feature.end1, feature.kind} }.each do |feature|
        unless lane = lanes.assign(feature)
          hidden += 1
          next
        end

        draw_feature(ctx, feature, lane, region, plot_left, top, plot_width)
      end
      if hidden > 0
        draw_notice(ctx, D4Plot.t("plot.additional_features", number: hidden), plot_left, top + height - 17, plot_width)
      end
    end

    private def draw_feature(ctx, feature, lane, region, plot_left, top, plot_width)
      x1 = plot_left + (feature.start1.to_i64 - 1 - region.start0).to_f / region.length * plot_width
      x2 = plot_left + (feature.end1.to_i64 - region.start0).to_f / region.length * plot_width
      x1 = x1.clamp(plot_left, plot_left + plot_width)
      x2 = x2.clamp(plot_left, plot_left + plot_width)
      feature_width = {x2 - x1, 1.0}.max
      y = top + 18.0 + lane * LANE

      if feature.kind == "exon"
        draw_box(ctx, x1, y - 4.0, feature_width, 8.0, 0.12, 0.36, 0.52)
      else
        draw_line(ctx, x1, x2, y, feature.strand)
        draw_label(ctx, feature.name || feature.kind, x1 + 3.0, y - 18.0, feature_width - 6.0) if feature_width > 34.0
      end
    end

    private def draw_line(ctx, x1, x2, y, strand)
      brush = UIng::Area::Draw::Brush.new(:solid, 0.18, 0.28, 0.34, 1.0)
      ctx.stroke_path(brush, thickness: 1.0) do |path|
        path.new_figure(x1, y)
        path.line_to(x2, y)
        if (strand == "+" || strand == "-") && x2 - x1 > 12
          direction = strand == "+" ? 1.0 : -1.0
          tip = strand == "+" ? x2 - 2 : x1 + 2
          path.new_figure(tip - 4 * direction, y - 3)
          path.line_to(tip, y)
          path.line_to(tip - 4 * direction, y + 3)
        end
      end
    end

    private def draw_box(ctx, x, y, width, height, red, green, blue)
      brush = UIng::Area::Draw::Brush.new(:solid, red, green, blue, 0.9)
      ctx.fill_path(brush) do |path|
        path.add_rectangle(x, y, width, height)
      end
    end

    private def draw_label(ctx, text, x, y, width)
      # Keep names on one lane; TextLayout otherwise wraps long names across
      # neighbouring features. Strand is drawn on the interval itself.
      characters = Math.max((width / 8).floor.to_i, 2)
      text = text[0, characters - 1] + "…" if text.size > characters
      UIng::Area::AttributedString.open(text) do |attr_str|
        attr_str.set_attribute(UIng::Area::Attribute.new_color(0.15, 0.15, 0.15, 1.0), 0_u64, text.bytesize.to_u64)

        UIng::Area::Draw::TextLayout.open(
          string: attr_str,
          default_font: label_font,
          width: width,
          align: UIng::Area::Draw::TextAlign::Left
        ) do |text_layout|
          ctx.draw_text_layout(text_layout, x, y)
        end
      end
    end

    private def label_font
      @label_font ||= UIng::FontDescriptor.new(size: 11)
    end
  end
end
