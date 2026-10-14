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
      if count = data["point_count"]?.try(&.as_i64?)
        settings.point_count = count.to_i if (16..4096).includes?(count)
      end
      if limit = data["annotation_feature_limit"]?.try(&.as_i64?)
        settings.annotation_feature_limit = limit.to_i if (1..5000).includes?(limit)
      end
      if mode = data["toolbar_display_mode"]?.try(&.as_s?).try { |name| UIng::Toolbar::DisplayMode.parse?(name) }
        settings.toolbar_display_mode = mode
      end
      use_sum_index = data["use_sum_index"]?.try(&.as_bool?)
      settings.use_sum_index = use_sum_index unless use_sum_index.nil?
      show_axis_ticks = data["show_axis_ticks"]?.try(&.as_bool?)
      settings.show_axis_ticks = show_axis_ticks unless show_axis_ticks.nil?
      zero = data["y_axis_from_zero"]?.try(&.as_bool?)
      settings.y_axis_from_zero = zero unless zero.nil?
      minimum = finite_number(data["y_min"]?)
      maximum = finite_number(data["y_max"]?)
      if minimum && maximum && minimum < maximum
        settings.y_min = minimum
        settings.y_max = maximum
      end
      if color = data["plot_color"]?.try(&.as_a?)
        channels = color.compact_map { |channel| finite_number(channel) }
        if color.size == 4 && channels.size == 4 && channels.all? { |channel| (0.0..1.0).includes?(channel) }
          settings.plot_color = {channels[0], channels[1], channels[2], channels[3]}
        end
      end
      if lines = data["h_lines"]?.try(&.as_a?)
        settings.h_lines = lines.compact_map { |line| finite_number(line) }.uniq.sort
      end
      settings
    end

    private def self.finite_number(value : JSON::Any?) : Float64?
      number = value.try(&.as_f?) || value.try(&.as_i64?).try(&.to_f)
      number if number && number.finite?
    end

    def y_range(min_value : Float64, max_value : Float64) : Tuple(Float64, Float64)
      low = @y_axis_from_zero ? Math.min(0.0, min_value) : min_value
      high = @y_axis_from_zero ? Math.max(0.0, max_value) : max_value
      padding = high == low ? Math.max(high.abs * 0.1, 1.0) : (high - low) * 0.08
      low -= padding unless @y_axis_from_zero && low == 0
      high += padding
      low = @y_min || low
      high = @y_max || high
      high = low + 1.0 if high <= low
      {low, high}
    end
  end
end
