require "uing"
require "json"
require "./data_sampler"

module D4Plot
  class PlotSettings
    alias PlotColor = Tuple(Float64, Float64, Float64, Float64)

    property point_count : Int32
    property annotation_feature_limit : Int32
    property toolbar_display_mode : UIng::Toolbar::DisplayMode
    property plot_color : PlotColor
    property? use_sum_index : Bool
    property? show_axis_ticks : Bool
    property? y_axis_from_zero : Bool
    property y_min : Float64?
    property y_max : Float64?
    property h_lines : Array(Float64)

    def initialize
      @point_count = DataSampler::DEFAULT_POINT_COUNT
      @annotation_feature_limit = 500
      @toolbar_display_mode = UIng::Toolbar::DisplayMode::IconAndTextVertical
      @plot_color = {0.16, 0.42, 0.58, 1.0}
      @use_sum_index = true
      @show_axis_ticks = true
      @y_axis_from_zero = true
      @y_min = nil
      @y_max = nil
      @h_lines = [] of Float64
    end

    def to_json(json : JSON::Builder)
      {point_count: @point_count, annotation_feature_limit: @annotation_feature_limit,
       toolbar_display_mode: @toolbar_display_mode.to_s, plot_color: @plot_color,
       use_sum_index: @use_sum_index, show_axis_ticks: @show_axis_ticks,
       y_axis_from_zero: @y_axis_from_zero, y_min: @y_min, y_max: @y_max,
       h_lines: @h_lines}.to_json(json)
    end

    # Validate each saved field independently so older or partially damaged
    # preferences can still supply the remaining settings.
    def self.from_preferences(value : JSON::Any?) : self
      settings = new
      return settings unless data = value.try(&.as_h?)
      restore_counts(settings, data)
      restore_display(settings, data)
      restore_scale(settings, data)
      restore_color(settings, data)
      restore_lines(settings, data)
      settings
    end

    private def self.restore_counts(settings, data) : Nil
      if count = data["point_count"]?.try(&.as_i64?)
        settings.point_count = count.to_i if (16..4096).includes?(count)
      end
      if limit = data["annotation_feature_limit"]?.try(&.as_i64?)
        settings.annotation_feature_limit = limit.to_i if (1..5000).includes?(limit)
      end
    end

    private def self.restore_display(settings, data) : Nil
      if mode = data["toolbar_display_mode"]?.try(&.as_s?).try { |name| UIng::Toolbar::DisplayMode.parse?(name) }
        settings.toolbar_display_mode = mode
      end
      use_sum_index = data["use_sum_index"]?.try(&.as_bool?)
      settings.use_sum_index = use_sum_index unless use_sum_index.nil?
      show_axis_ticks = data["show_axis_ticks"]?.try(&.as_bool?)
      settings.show_axis_ticks = show_axis_ticks unless show_axis_ticks.nil?
      zero = data["y_axis_from_zero"]?.try(&.as_bool?)
      settings.y_axis_from_zero = zero unless zero.nil?
    end

    private def self.restore_scale(settings, data) : Nil
      minimum = finite_number(data["y_min"]?)
      maximum = finite_number(data["y_max"]?)
      if minimum && maximum && valid_y_limits?(minimum, maximum)
        settings.y_min = minimum
        settings.y_max = maximum
      end
    end

    private def self.restore_color(settings, data) : Nil
      if color = data["plot_color"]?.try(&.as_a?)
        channels = color.compact_map { |channel| finite_number(channel) }
        if color.size == 4 && channels.size == 4 && channels.all? { |channel| (0.0..1.0).includes?(channel) }
          settings.plot_color = {channels[0], channels[1], channels[2], channels[3]}
        end
      end
    end

    private def self.restore_lines(settings, data) : Nil
      if lines = data["h_lines"]?.try(&.as_a?)
        settings.h_lines = lines.compact_map { |line| finite_number(line) }.uniq!.sort!
      end
    end

    private def self.finite_number(value : JSON::Any?) : Float64?
      number = value.try(&.as_f?) || value.try(&.as_i64?).try(&.to_f)
      number if number && number.finite?
    end

    def self.valid_y_limits?(minimum : Float64, maximum : Float64) : Bool
      minimum.finite? && maximum.finite? && minimum < maximum && (maximum - minimum).finite?
    end

    def y_range(min_value : Float64, max_value : Float64) : Tuple(Float64, Float64)
      raise ArgumentError.new("Plot values must be finite") unless min_value.finite? && max_value.finite?
      if range = fixed_y_range
        return range
      end
      low = @y_axis_from_zero ? Math.min(0.0, min_value) : min_value
      high = @y_axis_from_zero ? Math.max(0.0, max_value) : max_value
      low, high = padded_range(low, high)
      fallback = {low, high}
      low, high = partial_y_range(low, high)
      valid_plot_range?(low, high) ? {low, high} : fallback
    end

    # Interpolate opposite-signed extreme endpoints without materializing an
    # infinite span. These helpers keep native drawing and SVG coordinates
    # finite for valid, very large D4 scaling factors.
    def self.interpolate(low : Float64, high : Float64, fraction : Float64) : Float64
      return low if fraction <= 0.0
      return high if fraction >= 1.0
      span = high - low
      return low + span * fraction if span.finite?
      low * (1.0 - fraction) + high * fraction
    end

    def self.normalized_position(value : Float64, low : Float64, high : Float64) : Float64
      span = high - low
      if span.finite?
        ((value - low) / span).clamp(0.0, 1.0)
      else
        scale = Math.max(low.abs, high.abs)
        (((value / scale) - (low / scale)) / ((high / scale) - (low / scale))).clamp(0.0, 1.0)
      end
    end

    private def fixed_y_range : Tuple(Float64, Float64)?
      minimum = @y_min
      maximum = @y_max
      return unless minimum && maximum
      {minimum, maximum} if self.class.valid_y_limits?(minimum, maximum)
    end

    private def padded_range(low : Float64, high : Float64) : Tuple(Float64, Float64)
      padding = if high == low
                  Math.max(high.abs * 0.1, 1.0)
                else
                  span = high - low
                  span.finite? ? span * 0.08 : 0.0
                end
      padded_low = low - padding
      padded_high = high + padding
      low = padded_low if padded_low.finite? && !(@y_axis_from_zero && low == 0.0)
      high = padded_high if padded_high.finite?
      return {low, high} if valid_plot_range?(low, high)

      # A singleton at Float64's limit cannot be expanded upward. Expanding
      # toward zero still yields a useful, finite range.
      if high == low && high > 0.0
        return {high * 0.9, high}
      elsif high == low && low < 0.0
        return {low, low * 0.9}
      end
      {-1.0, 1.0}
    end

    private def partial_y_range(low : Float64, high : Float64) : Tuple(Float64, Float64)
      return {low, high} if @y_min && @y_max
      minimum = @y_min
      maximum = @y_max
      {minimum && minimum.finite? ? minimum : low, maximum && maximum.finite? ? maximum : high}
    end

    private def valid_plot_range?(low : Float64, high : Float64) : Bool
      low.finite? && high.finite? && low < high
    end
  end
end
