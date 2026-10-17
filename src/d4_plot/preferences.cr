require "json"
require "path"
require "./i18n"
require "./plot_settings"
require "./background_io"

module D4Plot
  # Loading preferences does not create native UI controls.
  class Preferences
    getter path : String
    property locale : String?
    getter settings = PlotSettings.new
    property height_index = 1
    property? shared_y = false
    property? sidebar_visible = true

    def initialize(@path = self.class.default_path, @locale : String? = nil)
    end

    def self.load(path = default_path) : self
      preference = new(path)
      return preference unless File.file?(path)

      begin
        data = JSON.parse(File.read(path)).as_h?
        return preference unless data
        locale = data["locale"]?.try(&.as_s?)
        preference.locale = locale if locale && Translations.supported?(locale)
        preference.load_display(data)
      rescue ex : JSON::ParseException | File::Error
        # A damaged preference should never prevent the GUI from starting.
        Logging.report_warning(Log, "preferences.defaults_used", ex)
      end
      preference
    end

    protected def load_display(data)
      @settings = PlotSettings.from_preferences(data["display"]?)
      if height = data["track_height"]?.try(&.as_i64?)
        @height_index = height.to_i if (0..2).includes?(height)
      end
      @shared_y = data["shared_y"]?.try(&.as_bool?) || false
      @sidebar_visible = data["sidebar_visible"]?.try(&.as_bool?) != false
    end

    def save(settings : PlotSettings = @settings, locale : String? = @locale) : Nil
      self.class.write(@path, serialized(settings, locale))
      @settings = settings
      @locale = locale
    end

    # Apply immediately in memory, then persist an immutable snapshot in order.
    # A failed older save must never roll back more recent user changes.
    def save_async(io : BackgroundIO, settings : PlotSettings = @settings, locale : String? = @locale, &done : Exception? -> Nil) : Nil
      path = @path
      data = serialized(settings, locale)
      io.submit(-> { Preferences.write(path, data) }, operation: "preferences.save", &done)
      @settings = settings
      @locale = locale
    end

    private def serialized(settings, locale) : String
      {locale: locale, display: settings, track_height: @height_index, shared_y: @shared_y, sidebar_visible: @sidebar_visible}.to_json
    end

    def self.write(path : String, data : String) : Nil
      Dir.mkdir_p(File.dirname(path))
      # Publish a complete file, leaving the old preferences intact on failure.
      File.tempfile(".d4-plot-settings", ".json", dir: File.dirname(path)) do |file|
        file.puts(data)
        file.close
        File.rename(file.path, path)
      ensure
        File.delete(file.path) if File.exists?(file.path)
      end
    end

    def self.default_path : String
      {% if flag?(:win32) %}
        base = absolute_environment_directory("APPDATA", "LOCALAPPDATA") || Path.home.to_s
        File.join(base, "D4 Plot", "settings.json")
      {% elsif flag?(:darwin) %}
        File.join(Path.home, "Library", "Application Support", "D4 Plot", "settings.json")
      {% else %}
        base = absolute_environment_directory("XDG_CONFIG_HOME") || File.join(Path.home, ".config")
        File.join(base, "d4-plot", "settings.json")
      {% end %}
    end

    # XDG and Windows application-data variables name directories. Empty or
    # relative values would otherwise make preferences appear in the process
    # working directory, so fall back to the platform default instead.
    private def self.absolute_environment_directory(*names : String) : String?
      names.each do |name|
        if value = ENV[name]?
          return value if !value.empty? && Path.new(value).absolute?
        end
      end
      nil
    end
  end
end
