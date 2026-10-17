require "./data_sampler"

module D4Plot
  module DisplayFormat
    def self.position(value : Int) : String
      value.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
    end

    def self.value(value : Float64) : String
      "%.5g" % value
    end
  end

  # Bin edges are retained through the region and count, without materializing
  # per-base data. All rendering, inspection and export use these same edges.
  class SampledView
    getter region : Region
    getter points : Array(PlotPoint)
    getter minimum : Float64, maximum : Float64, mean : Float64

    def initialize(@region : Region, @points : Array(PlotPoint))
      raise ArgumentError.new(D4Plot.t("errors.no_samples")) if points.empty?
      raise ArgumentError.new("Sample values must be finite") unless points.all?(&.[1].finite?)
      @minimum = points.min_of(&.[1])
      @maximum = points.max_of(&.[1])
      @mean = weighted_mean
    end

    def bin_edges(index : Int32) : Tuple(Int64, Int64)
      base = @region.length.to_i64 // @points.size
      extra = @region.length.to_i64 % @points.size
      left = @region.start0.to_i64 + index * base + Math.min(index, extra)
      {left, left + base + (index < extra ? 1 : 0)}
    end

    def bin_at(fraction : Float64) : Int32
      offset = (fraction.clamp(0.0, 1.0) * @region.length).floor.to_i64.clamp(0_i64, @region.length.to_i64 - 1)
      base = @region.length.to_i64 // @points.size
      extra = @region.length.to_i64 % @points.size
      boundary = (base + 1) * extra
      (offset < boundary ? offset // (base + 1) : extra + (offset - boundary) // base).to_i
    end

    private def weighted_mean : Float64
      total = 0.0
      @points.each_with_index do |point, index|
        left, right = bin_edges(index)
        total += point[1] * (right - left)
      end
      mean = total / @region.length
      return mean if mean.finite?

      # The weighted mean is bounded by the sample extrema, but multiplying a
      # finite scaled sample by its bin length can overflow before division.
      # Normalize first when that happens.
      scale = @points.max_of(&.[1].abs)
      return 0.0 if scale == 0.0
      normalized = 0.0
      @points.each_with_index do |point, index|
        left, right = bin_edges(index)
        normalized += point[1] / scale * (right - left).to_f64 / @region.length
      end
      normalized.clamp(-1.0, 1.0) * scale
    end

    def resolution : String
      return D4Plot.t("view.one_bp_per_bin") if @points.size == @region.length
      base = @region.length // @points.size
      width = DisplayFormat.position(base)
      width += "–#{DisplayFormat.position(base + 1)}" if @region.length % @points.size != 0
      D4Plot.t("view.resolution", width: width)
    end

    def inspect_bin(index : Int32) : String
      left, right = bin_edges(index)
      D4Plot.t("view.bin_inspection", chromosome: @region.chromosome, start: DisplayFormat.position(left + 1),
        end: DisplayFormat.position(right), mean: DisplayFormat.value(@points[index][1]), bases: DisplayFormat.position(right - left))
    end

    def write_bedgraph(io : IO) : Nil
      io << "# Binned means; coordinates: 0-based, half-open; D4 denominator applied\n"
      @points.each_with_index do |point, index|
        left, right = bin_edges(index)
        io << @region.chromosome << '\t' << left << '\t' << right << '\t' << point[1] << '\n'
      end
    end
  end

  class ViewHistory
    @regions = [] of Region
    @cursor = -1

    def clear : Nil
      @regions.clear
      @cursor = -1
    end

    def retain(chromosomes : Hash(String, UInt32)) : Nil
      valid = ->(region : Region) { chromosomes[region.chromosome]?.try { |size| region.end1 <= size } || false }
      @cursor = @regions.first(@cursor + 1).count { |region| valid.call(region) } - 1
      @regions.select! { |region| valid.call(region) }
    end

    def record(region : Region) : Nil
      return if @cursor >= 0 && @regions[@cursor]? == region
      @regions = @regions[0, @cursor + 1]
      @regions << region
      @regions.shift if @regions.size > 100
      @cursor = @regions.size - 1
    end

    def back? : Bool
      @cursor > 0
    end

    def forward? : Bool
      @cursor + 1 < @regions.size
    end

    def back : Region?
      return unless back?
      @cursor -= 1
      @regions[@cursor]
    end

    def forward : Region?
      return unless forward?
      @cursor += 1
      @regions[@cursor]
    end
  end
end
