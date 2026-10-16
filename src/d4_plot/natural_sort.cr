module D4Plot
  module NaturalSort
    extend self

    # Compares embedded ASCII digit runs by numeric magnitude without parsing
    # them into a fixed-width integer. This keeps arbitrarily long identifiers
    # sortable and places `track2` before `track10`.
    def compare(left : String, right : String) : Int32
      comparison = compare_chunks(left.downcase, right.downcase)
      return comparison unless comparison == 0

      # Use the original spelling as a deterministic tie-breaker after the
      # case-insensitive comparison.
      compare_chunks(left, right)
    end

    private def compare_chunks(left : String, right : String) : Int32
      left_chunks = chunks(left)
      right_chunks = chunks(right)
      common_size = Math.min(left_chunks.size, right_chunks.size)

      common_size.times do |index|
        left_chunk = left_chunks[index]
        right_chunk = right_chunks[index]
        comparison = if digit_chunk?(left_chunk) && digit_chunk?(right_chunk)
                       compare_digits(left_chunk, right_chunk)
                     else
                       left_chunk <=> right_chunk
                     end
        return comparison unless comparison == 0
      end

      left_chunks.size <=> right_chunks.size
    end

    private def chunks(value : String) : Array(String)
      value.scan(/[0-9]+|[^0-9]+/).map(&.[0])
    end

    private def digit_chunk?(value : String) : Bool
      !value.empty? && value.byte_at(0).in?(48_u8..57_u8)
    end

    private def compare_digits(left : String, right : String) : Int32
      left_significant = significant_digits(left)
      right_significant = significant_digits(right)

      comparison = left_significant.bytesize <=> right_significant.bytesize
      return comparison unless comparison == 0
      comparison = left_significant <=> right_significant
      return comparison unless comparison == 0

      # Numerically equal runs use the shorter spelling first: 2, 02, 002.
      left.bytesize <=> right.bytesize
    end

    private def significant_digits(value : String) : String
      first = 0
      while first < value.bytesize - 1 && value.byte_at(first) == 48_u8
        first += 1
      end
      value.byte_slice(first, value.bytesize - first)
    end
  end
end
