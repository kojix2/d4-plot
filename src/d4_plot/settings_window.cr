require "uing"
require "./i18n"
require "./plot_settings"
require "./preferences"

module D4Plot
  class SettingsWindow
    TOOLBAR_MODES = [
      UIng::Toolbar::DisplayMode::IconAndTextVertical,
      UIng::Toolbar::DisplayMode::IconAndTextHorizontal,
      UIng::Toolbar::DisplayMode::IconOnly,
      UIng::Toolbar::DisplayMode::TextOnly,
    ]

    @destroyed = false

    def initialize(@settings : PlotSettings, @preferences : Preferences, @parent : UIng::Window, @background_io : BackgroundIO, @on_apply : Proc(Bool, Nil), @on_close : Proc(Nil))
      @window = UIng::Window.new(D4Plot.t("settings.title"), 460, 540, margined: true)
      @bins = UIng::Spinbox.new(16, 4096, @settings.point_count)
      @auto = UIng::Checkbox.new(D4Plot.t("settings.auto_scale"))
      @auto.checked = @settings.y_min.nil? && @settings.y_max.nil?
      @zero = UIng::Checkbox.new(D4Plot.t("settings.include_zero"))
      @zero.checked = @settings.y_axis_from_zero?
      @min = UIng::Entry.new
      @min.text = (@settings.y_min || 0.0).to_s
      @max = UIng::Entry.new
      @max.text = (@settings.y_max || 100.0).to_s
      @lines = UIng::Entry.new
      @lines.text = @settings.h_lines.join(", ")
      @color = UIng::ColorButton.new
      @color.set_color(*@settings.plot_color)
      @limit = UIng::Spinbox.new(1, 5000, @settings.annotation_feature_limit)
      @public_source = UIng::Combobox.new
      {"UCSC", "Ensembl"}.each { |name| @public_source.append(name) }
      @public_source.selected = @settings.public_annotation_source == "ensembl" ? 1 : 0
      @toolbar_mode = UIng::Combobox.new
      ["settings.toolbar_vertical", "settings.toolbar_horizontal", "settings.toolbar_icons", "settings.toolbar_labels"].each { |key| @toolbar_mode.append(D4Plot.t(key)) }
      @toolbar_mode.selected = TOOLBAR_MODES.index(@settings.toolbar_display_mode)
      @language = UIng::Combobox.new
      @language.append(D4Plot.t("settings.system_language"))
      Translations.locale_choices.each { |(locale, name)| @language.append("#{name} (#{locale})") }
      @language.selected = @preferences.locale.try { |locale| Translations::SUPPORTED_LOCALES.index(locale).try(&.+(1)) } || 0
      form = UIng::Form.new
      form.padded = true
      form.append(D4Plot.t("settings.bins"), @bins)
      form.append(D4Plot.t("settings.y_scale"), @auto)
      form.append("", @zero)
      form.append(D4Plot.t("settings.fixed_minimum"), @min)
      form.append(D4Plot.t("settings.fixed_maximum"), @max)
      form.append(D4Plot.t("settings.reference_lines"), @lines)
      form.append(D4Plot.t("settings.signal_color"), @color)
      form.append(D4Plot.t("settings.annotation_limit"), @limit)
      form.append(D4Plot.t("settings.public_source"), @public_source)
      form.append(D4Plot.t("settings.toolbar"), @toolbar_mode)
      form.append(D4Plot.t("settings.language"), @language)
      root = UIng::Box.new(:vertical)
      root.padded = true
      root.append(form, false)
      root.append(UIng::Label.new(D4Plot.t("settings.hint")), false)
      root.append(UIng::Box.new(:vertical), true)
      buttons = UIng::Box.new(:horizontal)
      buttons.padded = true
      apply = UIng::Button.new(D4Plot.t("settings.apply"))
      close = UIng::Button.new(D4Plot.t("settings.close"))
      buttons.append(apply, false)
      buttons.append(close, false)
      root.append(buttons, false)
      @window.child = root
      apply.on_clicked { apply_settings }
      close.on_clicked { @on_close.call; destroy }
      @window.on_closing { @destroyed = true; @on_close.call; true }
      @auto.on_toggled { sync_scale_controls }
      sync_scale_controls
    end

    def show
      @window.show
    end

    def destroy
      @destroyed = true
      @window.destroy
    end

    private def sync_scale_controls : Nil
      if @auto.checked?
        @min.disable
        @max.disable
        @zero.enable
      else
        @min.enable
        @max.enable
        @zero.disable
      end
    end

    private def number(text : String) : Float64
      value = text.strip.to_f?
      raise ArgumentError.new(D4Plot.t("settings.finite_number", text: text.inspect)) unless value && value.finite?
      value
    end

    private def data_settings_changed? : Bool
      @settings.point_count != @bins.value || @settings.annotation_feature_limit != @limit.value
    end

    private def apply_settings : Nil
      minimum, maximum = scale_limits
      lines = reference_lines
      reload_data = data_settings_changed?
      selected_locale = (@language.selected || 0) == 0 ? nil : Translations::SUPPORTED_LOCALES[(@language.selected || 1) - 1]
      previous_locale = @preferences.locale
      language_changed = previous_locale != selected_locale
      candidate = settings_candidate(minimum, maximum, lines)
      @preferences.save_async(@background_io, settings: candidate, locale: selected_locale) do |error|
        if error
          @parent.msg_box_error(D4Plot.t("app.preferences_error"), error.message || error.class.name)
        elsif language_changed && !@destroyed
          @window.msg_box(D4Plot.t("settings.language_saved_title"), D4Plot.t("settings.language_saved"))
        end
      end
      @settings = candidate
      @on_apply.call(reload_data)
    rescue ex : ArgumentError | File::Error
      @window.msg_box_error(D4Plot.t("settings.check"), ex.message || D4Plot.t("settings.invalid"))
    end

    private def settings_candidate(minimum : Float64?, maximum : Float64?, lines : Array(Float64)) : PlotSettings
      candidate = @settings.dup
      candidate.point_count = @bins.value
      candidate.y_min = minimum
      candidate.y_max = maximum
      candidate.y_axis_from_zero = @zero.checked?
      candidate.h_lines = lines
      candidate.plot_color = @color.color
      candidate.annotation_feature_limit = @limit.value
      candidate.public_annotation_source = (@public_source.selected || 0) == 1 ? "ensembl" : "ucsc"
      candidate.toolbar_display_mode = TOOLBAR_MODES.fetch(@toolbar_mode.selected || 0, TOOLBAR_MODES[0])
      candidate
    end

    private def scale_limits : Tuple(Float64?, Float64?)
      return {nil, nil} if @auto.checked?
      minimum = number(@min.text || "")
      maximum = number(@max.text || "")
      raise ArgumentError.new(D4Plot.t("settings.invalid_scale")) unless PlotSettings.valid_y_limits?(minimum, maximum)
      {minimum, maximum}
    end

    private def reference_lines : Array(Float64)
      (@lines.text || "").split(/[\s,;]+/).reject(&.empty?).map { |text| number(text) }.uniq!.sort!
    end
  end
end
