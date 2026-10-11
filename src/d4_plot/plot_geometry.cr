module D4Plot
  struct PlotGeometry
    getter left : Float64, top : Float64, width : Float64, height : Float64, annotation_top : Float64

    def initialize(area_width : Float64, area_height : Float64, annotation_height : Float64, top : Float64 = 92.0)
      @left = 82.0
      @top = top
      @width = Math.max(area_width - @left - 38.0, 1.0)
      @height = Math.max(area_height - @top - 58.0 - annotation_height - (annotation_height > 0 ? 28.0 : 0.0), 1.0)
      @annotation_top = @top + @height + 58.0
    end

    def fraction(x : Float64) : Float64
      ((x - @left) / @width).clamp(0.0, 1.0)
    end

    def contains?(x : Float64, y : Float64) : Bool
      x >= @left && x <= @left + @width && y >= @top && y <= @top + @height
    end

    # Position is a 0-based boundary, shared by bins and annotation intervals.
    def x_for(position : Int64, region : Region) : Float64
      @left + (position - region.start0).to_f64 / region.length * @width
    end
  end

  # Geometry is in document coordinates. libui already adjusts scrolling-area
  # draw clips and mouse events; applying a second scroll offset is incorrect.
  struct StackGeometry
    HEADER = 78.0
    getter width : Float64, row_height : Float64, count : Int32

    def initialize(@width, @row_height, @count); end

    def row_top(index : Int32)
      HEADER + index * row_height
    end

    def plot(index : Int32)
      PlotGeometry.new(width, row_top(index) + row_height, 0.0, row_top(index) + 34.0)
    end

    def index_at(y : Float64) : Int32?
      return if y < HEADER
      index = ((y - HEADER) / row_height).floor.to_i
      index if index < count
    end

    def annotation_top
      HEADER + Math.max(count, 1) * row_height + 8.0
    end

    def height(annotation_height : Float64)
      Math.max(annotation_top + annotation_height + 24, 250.0).ceil.to_i
    end

    def visible?(index : Int32, clip_y : Float64, clip_height : Float64)
      row_top(index) < clip_y + clip_height && row_top(index) + row_height > clip_y
    end
  end
end
