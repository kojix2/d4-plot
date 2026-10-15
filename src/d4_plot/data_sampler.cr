require "d4"
require "./log"
require "./region"

module D4Plot
  alias PlotPoint = Tuple(UInt32, Float64)

  # A half-open bin used by data sources that do not share the GUI's
  # user-facing UInt32 coordinate model.  Web requests use Int64 end to end,
  # even though the current D4 format deliberately rejects contigs larger
  # than UInt32::MAX.
  record BinRange, start0 : Int64, end0 : Int64 do
    def length : Int64
      end0 - start0
    end
  end

  record SampledBin, start0 : Int64, end0 : Int64, value : Float64

  class DataSampler
    DEFAULT_POINT_COUNT         =        256
    MIN_INDEX_BIN_SIZE          = 65_536_i64
    DEFAULT_MAX_STREAMING_BASES = 64_i64 * 1024 * 1024

    # Older released d4.cr versions do not accept a cancellation callback.
    # The capability check keeps this shard buildable with them, while a
    # newer d4.cr automatically gains cancellation inside scan/index I/O.
    # `sum_index_granularity` was introduced together with that API.
    HAS_COOPERATIVE_D4_CANCELLATION = {{ D4::Track.has_method?(:sum_index_granularity) }}

    def self.downsample(d4 : D4::File | D4::Track, region : Region, npoints : Int32 = DEFAULT_POINT_COUNT, use_sum_index : Bool = true, cancelled : Proc(Bool)? = nil) : Array(PlotPoint)
      raise ArgumentError.new(D4Plot.t("errors.invalid_region")) unless region.valid?
      downsample(d4, region.chromosome, region.start0, region.end0_exclusive, npoints, use_sum_index, cancelled)
    end

    # Parameters are internal 0-based half-open [start0, end0_excl).
    # Returned coordinates are 1-based for user-facing axis display.
    def self.downsample(d4 : D4::File | D4::Track, chromosome : String, start0 : UInt32, end0_excl : UInt32, npoints : Int32 = DEFAULT_POINT_COUNT, use_sum_index : Bool = true, cancelled : Proc(Bool)? = nil) : Array(PlotPoint)
      return [] of PlotPoint if end0_excl <= start0
      return [] of PlotPoint if npoints <= 0

      track = d4.is_a?(D4::File) ? d4.default_track : d4
      raise ArgumentError.new(D4Plot.t("errors.region_exceeds_chromosome")) if end0_excl > track.chromosome_size(chromosome)
      total_len = end0_excl.to_i64 - start0
      count = Math.min(npoints.to_i64, total_len).to_i
      points = if use_sum_index && total_len // count >= index_bin_size(track) && track.has_index?(D4::IndexKind::Sum)
                 indexed_sample(track, chromosome, start0, end0_excl, count, cancelled)
               else
                 stream_sample(track, chromosome, start0, end0_excl, count, cancelled)
               end
      denominator = track.metadata.denominator
      if denominator != 1.0
        points.map! { |pos, value| {pos, value / denominator} }
      end
      points
    rescue ex : D4::CancelledError
      raise SamplingCancelled.new(ex.message || "D4 read was cancelled")
    end

    # Samples contiguous, explicit 0-based half-open bins.  This deliberately
    # does not reuse SampledView#bin_edges: the desktop view has equal bins
    # anchored at a requested interval, whereas web bins are fixed-grid bins
    # anchored at the chromosome origin.
    def self.sample_bins(track : D4::Track, chromosome : String, bins : Array(BinRange), use_sum_index : Bool = true,
                         cancelled : Proc(Bool)? = nil, max_streaming_bases : Int64 = DEFAULT_MAX_STREAMING_BASES) : Array(SampledBin)
      return [] of SampledBin if bins.empty?
      validate_bins!(track, chromosome, bins)
      raise ArgumentError.new("Streaming scan budget cannot be negative") if max_streaming_bases < 0
      indexed = use_sum_index && track.has_index?(D4::IndexKind::Sum) && bins.all? { |bin| bin.length >= index_bin_size(track) }
      sampled = if indexed
                  begin
                    indexed_bins(track, chromosome, bins, cancelled)
                  rescue D4::IndexPrecisionError | D4::MissingIndexError
                    require_streaming_budget!(bins, max_streaming_bases)
                    streamed_bins(track, chromosome, bins, cancelled)
                  end
                else
                  require_streaming_budget!(bins, max_streaming_bases)
                  streamed_bins(track, chromosome, bins, cancelled)
                end
      denominator = track.metadata.denominator
      return sampled if denominator == 1.0
      sampled.map! { |bin| SampledBin.new(bin.start0, bin.end0, bin.value / denominator) }
      sampled
    rescue ex : D4::CancelledError
      raise SamplingCancelled.new(ex.message || "D4 read was cancelled")
    end

    private def self.indexed_sample(d4 : D4::Track, chromosome : String, start0 : UInt32, end0_excl : UInt32, npoints : Int32, cancelled) : Array(PlotPoint)
      data = Array(PlotPoint).new(npoints)
      each_bin(start0, end0_excl, npoints) do |bin_start, bin_end_excl|
        raise SamplingCancelled.new if cancelled.try(&.call)
        center0 = (bin_start.to_u64 + bin_end_excl - 1) // 2
        sum = sum_with_cancellation(d4, chromosome, bin_start, bin_end_excl, D4::IndexPolicy::Auto, cancelled)
        data << {(center0 + 1).to_u32, sum.to_f64 / (bin_end_excl - bin_start)}
      end
      data
    end

    private def self.indexed_bins(track : D4::Track, chromosome : String, bins : Array(BinRange), cancelled) : Array(SampledBin)
      result = Array(SampledBin).new(bins.size)
      bins.each do |bin|
        raise SamplingCancelled.new if cancelled.try(&.call)
        sum = sum_with_cancellation(track, chromosome, bin.start0, bin.end0, D4::IndexPolicy::Require, cancelled)
        raise SamplingCancelled.new if cancelled.try(&.call)
        result << SampledBin.new(bin.start0, bin.end0, sum.to_f64 / bin.length)
      end
      result
    end

    private def self.streamed_bins(track : D4::Track, chromosome : String, bins : Array(BinRange), cancelled) : Array(SampledBin)
      result = Array(SampledBin).new(bins.size)
      bin_index = 0
      bin = bins[bin_index]
      sum = 0_i64
      scratch = Slice(Int32).new(65_536)

      scan_with_cancellation(track, D4::Region.new(chromosome, bins.first.start0, bins.last.end0), scratch, cancelled) do |block_start, values, size|
        raise SamplingCancelled.new if cancelled.try(&.call)
        offset = 0
        position = block_start
        while offset < size
          take = Math.min(size - offset, (bin.end0 - position).to_i)
          limit = offset + take
          while offset < limit
            sum += values.unsafe_fetch(offset)
            offset += 1
          end
          position += take
          next unless position == bin.end0

          result << SampledBin.new(bin.start0, bin.end0, sum.to_f64 / bin.length)
          bin_index += 1
          break if bin_index == bins.size
          bin = bins[bin_index]
          sum = 0_i64
        end
      end
      raise "D4 scan ended before the requested bins" unless result.size == bins.size
      result
    end

    private def self.validate_bins!(track : D4::Track, chromosome : String, bins : Array(BinRange)) : Nil
      previous_end = nil.as(Int64?)
      chromosome_size = track.chromosome_size(chromosome)
      bins.each do |bin|
        raise ArgumentError.new("Invalid bin boundary") if bin.start0 < 0 || bin.end0 <= bin.start0 || bin.end0 > chromosome_size
        if previous = previous_end
          raise ArgumentError.new("Bins must be contiguous") unless bin.start0 == previous
        end
        previous_end = bin.end0
      end
    end

    private def self.stream_sample(d4 : D4::Track, chromosome : String, start0 : UInt32, end0_excl : UInt32, npoints : Int32, cancelled) : Array(PlotPoint)
      length = end0_excl.to_i64 - start0
      base = length // npoints
      extra = length % npoints
      points = Array(PlotPoint).new(npoints)
      bin_index = 0
      bin_start = start0.to_i64
      bin_stop = bin_start + base + (bin_index < extra ? 1 : 0)
      sum = 0_i64
      scratch = Slice(Int32).new(65_536)
      scan_with_cancellation(d4, D4::Region.new(chromosome, bin_start, end0_excl.to_i64), scratch, cancelled) do |block_start, values, size|
        raise SamplingCancelled.new if cancelled.try(&.call)
        offset = 0
        while offset < size
          take = Math.min(size - offset, (bin_stop - block_start - offset).to_i)
          limit = offset + take
          while offset < limit
            sum += values.unsafe_fetch(offset)
            offset += 1
          end
          if block_start + offset == bin_stop
            center = (bin_start + bin_stop - 1) // 2 + 1
            points << {center.to_u32, sum.to_f64 / (bin_stop - bin_start)}
            bin_index += 1
            if bin_index < npoints
              bin_start = bin_stop
              bin_stop += base + (bin_index < extra ? 1 : 0)
              sum = 0_i64
            end
          end
        end
      end
      points
    end

    private def self.each_bin(start0 : UInt32, end0_excl : UInt32, npoints : Int32, & : UInt32, UInt32 ->)
      total_len = end0_excl - start0
      bins = Math.min(npoints.to_u32, total_len)
      base_size = total_len // bins
      extra_bases = total_len % bins

      current = start0
      bins.times do |index|
        width = base_size
        width += 1_u32 if index < extra_bases

        bin_start = current
        bin_end_excl = bin_start + width
        yield bin_start, bin_end_excl
        current = bin_end_excl
      end
    end

    private def self.index_bin_size(track : D4::Track) : Int64
      {% if D4::Track.has_method?(:sum_index_granularity) %}
        granularity = track.sum_index_granularity
        granularity && granularity > 0 ? granularity : MIN_INDEX_BIN_SIZE
      {% else %}
        MIN_INDEX_BIN_SIZE
      {% end %}
    end

    private def self.sum_with_cancellation(track : D4::Track, chromosome : String, start0 : Int, end0 : Int,
                                           index : D4::IndexPolicy, cancelled : Proc(Bool)?) : Int64
      {% if D4::Track.has_method?(:sum_index_granularity) %}
        track.sum(chromosome, start0, end0, index: index, cancelled: cancelled)
      {% else %}
        track.sum(chromosome, start0, end0, index: index)
      {% end %}
    end

    private def self.require_streaming_budget!(bins : Array(BinRange), maximum : Int64) : Nil
      bases = bins.last.end0 - bins.first.start0
      return if bases <= maximum
      raise SamplingBudgetExceeded.new("Exact D4 aggregation would scan #{bases} bases (limit #{maximum}); zoom in or use a D4 file with a sum index")
    end

    private def self.scan_with_cancellation(track : D4::Track, region : D4::Region, buffer : Slice(Int32),
                                            cancelled : Proc(Bool)?, & : Int64, Slice(Int32), Int32 -> Nil) : Nil
      {% if D4::Track.has_method?(:sum_index_granularity) %}
        track.scan_values(region, buffer, cancelled: cancelled) do |block_start, values, count|
          yield block_start, values, count
        end
      {% else %}
        track.scan_values(region, buffer) do |block_start, values, count|
          yield block_start, values, count
        end
      {% end %}
    end
  end

  class SamplingCancelled < Exception
  end

  class SamplingBudgetExceeded < Exception
  end
end
