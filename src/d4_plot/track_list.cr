require "uing"
require "./track_layer"

module D4Plot
  # Owns the table model; the native table must be detached before free.
  class TrackList
    getter native : UIng::Table
    @model : UIng::Table::Model
    @rows = [] of TrackLayer
    @updating = false

    def initialize(on_select : Proc(Int32, Nil), on_toggle : Proc(Int32, Bool, Nil), on_sort : Proc(Bool, Nil))
      handler = UIng::Table::Model::Handler.new
      handler.num_columns { 2 }
      handler.column_type { |column| column == 0 ? UIng::Table::Value::Type::Int : UIng::Table::Value::Type::String }
      handler.num_rows { @rows.size }
      handler.cell_value do |row, column|
        layer = @rows[row]
        column == 0 ? UIng::Table::Value.new(layer.visible? ? 1 : 0) : UIng::Table::Value.new(layer.source.label)
      end
      handler.set_cell_value do |row, column, value|
        on_toggle.call(row, value.int != 0) if column == 0 && value && !@updating
      end
      @model = UIng::Table::Model.new(handler)
      @native = UIng::Table.new(@model)
      @native.append_checkbox_column(D4Plot.t("app.show"), 0, editable: :always)
      @native.append_text_column(D4Plot.t("app.track_list"), 1, editable: :never)
      @native.column_set_width(0, 48)
      @native.column_set_width(1, 228)
      @native.set_minimum_size(280, 100)
      @native.selection_mode = UIng::Table::Selection::Mode::One
      @native.on_selection_changed do |selection|
        if !@updating && (index = selection.rows.first?)
          on_select.call(index)
        end
      end
      @native.on_header_clicked do |column|
        next if column != 1 || @updating
        ascending = !@native.header_sort_indicator(column).ascending?
        show_sort(ascending)
        on_sort.call(ascending)
      end
    end

    def replace(layers : Array(TrackLayer), selected : Int32)
      @updating = true
      until @rows.empty?
        @rows.pop
        @model.row_deleted(@rows.size)
      end
      layers.each do |layer|
        @rows << layer
        @model.row_inserted(@rows.size - 1)
      end
      select_row(selected)
    ensure
      @updating = false
    end

    def select_row(index : Int32)
      previous = @updating
      @updating = true
      @native.selection = UIng::Table::Selection.new(@rows[index]? ? [index] : [] of Int32)
    ensure
      @updating = previous || false
    end

    def changed(index : Int32)
      @model.row_changed(index)
    end

    def show_sort(ascending : Bool)
      indicator = ascending ? UIng::Table::SortIndicator::Ascending : UIng::Table::SortIndicator::Descending
      @native.header_set_sort_indicator(1, indicator)
    end

    def clear_sort
      @native.header_set_sort_indicator(1, UIng::Table::SortIndicator::None)
    end

    def free
      @updating = true
      @native.destroy
      @model.free
    end
  end
end
