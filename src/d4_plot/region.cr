require "./i18n"

module D4Plot
  struct Region
    getter chromosome : String
    getter start1 : UInt32
    getter end1 : UInt32

    def initialize(@chromosome : String, @start1 : UInt32, @end1 : UInt32); end

    def self.parse(text : String) : Region?
      if match = text.strip.match(/^([^:\s]+)\s*:\s*(\d+|\d{1,3}(?:,\d{3})+)(?:\s*-\s*(\d+|\d{1,3}(?:,\d{3})+))?$/)
        start1 = match[2].delete(',').to_u32?
        end1 = (match[3]? || match[2]).delete(',').to_u32?
        return unless start1 && end1
        new(match[1], start1, end1)
      end
    end

    def self.resolve(text : String, chromosomes : Hash(String, UInt32)) : Region
      text = text.strip
      region = if size = chromosomes[text]?
                 new(text, 1_u32, size)
               else
                 parse(text) || raise ArgumentError.new(D4Plot.t("errors.region_format"))
               end
      region.validate!(chromosomes)
      region
    end

    def validate!(chromosomes : Hash(String, UInt32)) : Nil
      raise ArgumentError.new(D4Plot.t("errors.region_bounds")) unless valid?
      size = chromosomes[@chromosome]? || raise ArgumentError.new(D4Plot.t("errors.chromosome_not_found", chromosome: @chromosome.inspect))
      raise ArgumentError.new(D4Plot.t("errors.region_end", chromosome: @chromosome, size: size, end: @end1)) if @end1 > size
    end

    def self.bounded(chromosome : String, start0 : Int64, length : Int64, chromosome_size : UInt32) : Region
      raise ArgumentError.new(D4Plot.t("errors.empty_chromosome")) if chromosome_size == 0
      length = length.clamp(1_i64, chromosome_size.to_i64)
      left = start0.clamp(0_i64, chromosome_size.to_i64 - length)
      new(chromosome, (left + 1).to_u32, (left + length).to_u32)
    end

    def to_s(io : IO) : Nil
      io << @chromosome << ':' << @start1 << '-' << @end1
    end

    def valid?
      @start1 > 0 && @end1 >= @start1
    end

    def start0
      @start1 - 1_u32
    end

    def end0_exclusive
      @end1
    end

    def length
      end0_exclusive - start0
    end

    # One calculation for both the drag preview and the committed request.
    def pan(fraction : Float64, chromosome_size : UInt32) : Region
      delta = (fraction * length).round.to_i64
      Region.bounded(chromosome, start0.to_i64 + delta, length.to_i64, chromosome_size)
    end
  end
end
