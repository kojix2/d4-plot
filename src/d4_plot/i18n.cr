require "i18n"

module D4Plot
  # Loads the application catalogue once, before native windows or workers are
  # created. The loader embeds YAML files in release binaries, so the selected
  # language is available in every package without relying on its working
  # directory.
  module Translations
    SUPPORTED_LOCALES = {"en", "ja", "zh", "es", "de", "fr", "ko", "nl", "pt", "pl", "tr", "ru", "hi", "id", "ur", "vi", "he", "ar", "bn"}
    LOCALE_NAMES      = {"English", "日本語", "简体中文", "Español", "Deutsch", "Français", "한국어", "Nederlands", "Português", "Polski", "Türkçe", "Русский", "हिन्दी", "Bahasa Indonesia", "اردو", "Tiếng Việt", "עברית", "العربية", "বাংলা"}
    LOCALE_ALIASES    = {"iw" => "he", "in" => "id"}
    @@initialized = false

    def self.setup(requested_locale : String? = nil) : String
      return ::I18n.locale if @@initialized

      locale = resolve_locale(requested_locale)
      ::I18n.config.loaders = [::I18n::Loader::YAML.embed("config/locales")] of ::I18n::Loader::Base
      ::I18n.config.available_locales = SUPPORTED_LOCALES.to_a
      ::I18n.config.default_locale = locale
      ::I18n.config.fallbacks = ["en"]
      ::I18n.init
      @@initialized = true
      locale
    end

    def self.t(key : String, **kwargs) : String
      setup unless @@initialized
      ::I18n.t(key, **kwargs)
    end

    def self.locale_list : String
      SUPPORTED_LOCALES.join("|")
    end

    def self.locale_choices : Array(Tuple(String, String))
      SUPPORTED_LOCALES.zip(LOCALE_NAMES).map { |(locale, name)| {locale, name} }
    end

    # Resolves an explicit locale, or the operating system's preferred locale
    # when no preference was supplied. Unsupported languages fall back to
    # English.
    def self.resolve_locale(requested_locale : String? = nil) : String
      supported_locale(requested_locale || system_locale)
    end

    def self.supported?(locale : String) : Bool
      SUPPORTED_LOCALES.includes?(locale)
    end

    def self.usage : String
      t("cli.usage").sub(/\[--locale [^\]]+\]/, "[--locale #{locale_list}]")
    end

    private def self.system_locale : String?
      if locale = ENV["LC_ALL"]? || ENV["LC_MESSAGES"]? || ENV["LANGUAGE"]? || ENV["LANG"]?
        return locale
      end

      native_system_locale
    end

    private def self.supported_locale(value : String?) : String
      return "en" unless value
      language = value.downcase.split(/[_.@:-]/, 2).first
      language = LOCALE_ALIASES[language]? || language
      SUPPORTED_LOCALES.includes?(language) ? language : "en"
    end

    {% if flag?(:darwin) %}
      @[Link(framework: "CoreFoundation")]
      lib CoreFoundation
        fun CFLocaleCopyPreferredLanguages : Void*
        fun CFArrayGetCount(array : Void*) : Int64
        fun CFArrayGetValueAtIndex(array : Void*, index : Int64) : Void*
        fun CFStringGetCString(string : Void*, buffer : UInt8*, buffer_size : Int64, encoding : UInt32) : UInt8
        fun CFRelease(object : Void*)
      end

      private def self.native_system_locale : String?
        languages = CoreFoundation.CFLocaleCopyPreferredLanguages
        return nil if languages.null?
        begin
          return nil if CoreFoundation.CFArrayGetCount(languages) == 0
          value = CoreFoundation.CFArrayGetValueAtIndex(languages, 0)
          buffer = Bytes.new(256)
          if CoreFoundation.CFStringGetCString(value, buffer.to_unsafe, buffer.size, 0x08000100_u32) != 0
            String.new(buffer.to_unsafe)
          end
        ensure
          CoreFoundation.CFRelease(languages)
        end
      end
    {% elsif flag?(:win32) %}
      @[Link("kernel32")]
      lib Kernel32
        fun GetUserDefaultLocaleName(locale_name : UInt16*, locale_name_count : Int32) : Int32
      end

      private def self.native_system_locale : String?
        buffer = Slice(UInt16).new(85, 0_u16)
        length = Kernel32.GetUserDefaultLocaleName(buffer.to_unsafe, buffer.size)
        length > 1 ? String.from_utf16(buffer[0, length - 1]) : nil
      end
    {% else %}
      private def self.native_system_locale : String?
        nil
      end
    {% end %}
  end

  def self.t(key : String, **kwargs) : String
    Translations.t(key, **kwargs)
  end
end
