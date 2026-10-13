require "json"
require "path"
require "./i18n"

module D4Plot
  # Small, per-user preferences that must be known before libui is
  # initialized. Plot/display settings remain session-only for now.
  class Preferences
    getter path : String
    property locale : String?

    def initialize(@path = self.class.default_path, @locale : String? = nil)
    end

    def self.load(path = default_path) : self
      preference = new(path)
      return preference unless File.file?(path)

      begin
        locale = JSON.parse(File.read(path)).as_h?.try(&.["locale"]?).try(&.as_s?)
        preference.locale = locale if locale && Translations.supported?(locale)
      rescue JSON::ParseException | File::Error
        # A damaged preference should never prevent the GUI from starting.
      end
      preference
    end

    def save : Nil
      Dir.mkdir_p(File.dirname(@path))
      File.write(@path, {"locale" => @locale}.to_json + '\n')
    end

    def self.default_path : String
      {% if flag?(:win32) %}
        base = ENV["APPDATA"]? || ENV["LOCALAPPDATA"]? || Path.home.to_s
        File.join(base, "D4 Plot", "settings.json")
      {% elsif flag?(:darwin) %}
        File.join(Path.home, "Library", "Application Support", "D4 Plot", "settings.json")
      {% else %}
        base = ENV["XDG_CONFIG_HOME"]? || File.join(Path.home, ".config")
        File.join(base, "d4-plot", "settings.json")
      {% end %}
    end
  end
end
