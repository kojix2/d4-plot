require "uing"
require "./i18n"

module D4Plot
  # Owns the native toolbar and its borrowed images. Detach before freeing.
  class Toolbar
    getter native = UIng::Toolbar.new
    getter open : UIng::ToolbarItem
    getter create : UIng::ToolbarItem
    getter annotations : UIng::ToolbarItem
    getter export : UIng::ToolbarItem
    getter back : UIng::ToolbarItem
    getter forward : UIng::ToolbarItem
    getter left : UIng::ToolbarItem
    getter right : UIng::ToolbarItem
    getter zoom_in : UIng::ToolbarItem
    getter zoom_out : UIng::ToolbarItem
    getter whole : UIng::ToolbarItem
    getter cancel : UIng::ToolbarItem
    getter settings : UIng::ToolbarItem
    @images = [] of UIng::Image

    def initialize
      @native.display_mode = UIng::Toolbar::DisplayMode::IconOnly
      @open = button(D4Plot.t("toolbar.open"), D4Plot.t("toolbar.open_tip"), [[{2, 16}, {2, 4}, {8, 4}, {10, 6}, {18, 6}, {18, 16}, {2, 16}], [{2, 9}, {18, 9}]])
      @create = button(D4Plot.t("toolbar.create"), D4Plot.t("toolbar.create_tip"), [[{3, 2}, {12, 2}, {17, 7}, {17, 18}, {3, 18}, {3, 2}], [{12, 2}, {12, 7}, {17, 7}], [{6, 12}, {14, 12}], [{10, 8}, {10, 16}]])
      @annotations = button(D4Plot.t("toolbar.annotations"), D4Plot.t("toolbar.annotations_tip"), [[{2, 6}, {18, 6}], [{5, 3}, {5, 9}], [{8, 3}, {8, 9}], [{2, 14}, {18, 14}], [{12, 11}, {12, 17}], [{15, 11}, {15, 17}]])
      @export = button(D4Plot.t("toolbar.export"), D4Plot.t("toolbar.export_tip"), [[{10, 2}, {10, 12}], [{6, 8}, {10, 12}, {14, 8}], [{3, 13}, {3, 17}, {17, 17}, {17, 13}]])
      @native.append_separator
      @back = button(D4Plot.t("toolbar.back"), D4Plot.t("toolbar.back_tip"), [[{8, 4}, {2, 10}, {8, 16}], [{2, 10}, {18, 10}]])
      @forward = button(D4Plot.t("toolbar.forward"), D4Plot.t("toolbar.forward_tip"), [[{12, 4}, {18, 10}, {12, 16}], [{2, 10}, {18, 10}]])
      @native.append_separator
      @left = button(D4Plot.t("toolbar.left"), D4Plot.t("toolbar.left_tip"), [[{8, 5}, {3, 10}, {8, 15}], [{3, 10}, {14, 10}], [{17, 4}, {17, 16}]])
      @right = button(D4Plot.t("toolbar.right"), D4Plot.t("toolbar.right_tip"), [[{12, 5}, {17, 10}, {12, 15}], [{6, 10}, {17, 10}], [{3, 4}, {3, 16}]])
      lens = [[{4, 3}, {10, 3}, {13, 6}, {13, 10}, {10, 13}, {4, 13}, {1, 10}, {1, 6}, {4, 3}], [{12, 12}, {18, 18}], [{4, 8}, {10, 8}]]
      @zoom_out = button(D4Plot.t("toolbar.zoom_out"), D4Plot.t("toolbar.zoom_out_tip"), lens)
      @zoom_in = button(D4Plot.t("toolbar.zoom_in"), D4Plot.t("toolbar.zoom_in_tip"), lens + [[{7, 5}, {7, 11}]])
      @whole = button(D4Plot.t("toolbar.whole"), D4Plot.t("toolbar.whole_tip"), [[{2, 4}, {2, 16}], [{18, 4}, {18, 16}], [{2, 10}, {18, 10}], [{6, 6}, {2, 10}, {6, 14}], [{14, 6}, {18, 10}, {14, 14}]])
      @cancel = button(D4Plot.t("toolbar.cancel"), D4Plot.t("toolbar.cancel_tip"), [[{5, 5}, {15, 15}], [{5, 15}, {15, 5}]])
      @native.append_separator
      @settings = button(D4Plot.t("toolbar.display"), D4Plot.t("toolbar.display_tip"), [[{3, 5}, {17, 5}], [{3, 10}, {17, 10}], [{3, 15}, {17, 15}], [{7, 3}, {7, 7}], [{13, 8}, {13, 12}], [{7, 13}, {7, 17}]])
    end

    def free
      @native.free
      @images.each &.free
      @images.clear
    end

    private def button(text, tooltip, strokes) : UIng::ToolbarItem
      icon = icon(strokes)
      @images << icon
      item = @native.append_button(text, icon)
      item.tooltip = tooltip
      item
    end

    # Small line icons at 1× and 2×, with no image files or decoding dependency.
    private def icon(strokes) : UIng::Image
      image = UIng::Image.new(20, 20)
      {1, 2}.each do |scale|
        size = 20 * scale
        pixels = Bytes.new(size * size * 4)
        size.times do |y|
          size.times do |x|
            distance = Float64::INFINITY
            strokes.each do |stroke|
              stroke.each_cons_pair do |from, destination|
                dx, dy = destination[0] - from[0], destination[1] - from[1]
                px, py = (x + 0.5) / scale - from[0], (y + 0.5) / scale - from[1]
                fraction = ((px * dx + py * dy) / (dx * dx + dy * dy)).clamp(0.0, 1.0)
                distance = Math.min(distance, Math.sqrt((px - fraction * dx)**2 + (py - fraction * dy)**2))
              end
            end
            offset = (y * size + x) * 4
            pixels[offset] = 50
            pixels[offset + 1] = 129
            pixels[offset + 2] = 181
            alpha = ((0.85 - distance) * scale + 0.5).clamp(0.0, 1.0)
            pixels[offset + 3] = (alpha * 255).round.to_u8
          end
        end
        image.append(pixels, size, size, size * 4)
      end
      image
    end
  end
end
