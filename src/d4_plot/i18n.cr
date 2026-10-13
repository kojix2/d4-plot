require "i18n"

module D4Plot
  # Loads the application catalogue once, before native windows or workers are
  # created. The loader embeds YAML files in release binaries, so the selected
  # language is available in every package without relying on its working
  # directory.
  module Translations
    SUPPORTED_LOCALES = {"en", "ja", "zh", "es", "de", "fr", "ko", "nl", "pt", "pl", "tr", "ru", "hi", "id", "ur", "vi", "he", "ar", "bn"}
    LOCALE_ALIASES    = {"iw" => "he", "in" => "id"}
    @@initialized = false

    def self.setup(requested_locale : String? = nil) : String
      return ::I18n.locale if @@initialized

      locale = supported_locale(requested_locale || system_locale)
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

    def self.usage : String
      t("cli.usage").sub(/\[--locale [^\]]+\]/, "[--locale #{locale_list}]")
    end

    private def self.system_locale : String?
      ENV["LC_ALL"]? || ENV["LC_MESSAGES"]? || ENV["LANG"]?
    end

    private def self.supported_locale(value : String?) : String
      return "en" unless value
      language = value.downcase.split(/[_.@-]/, 2).first
      language = LOCALE_ALIASES[language]? || language
      SUPPORTED_LOCALES.includes?(language) ? language : "en"
    end
  end

  def self.t(key : String, **kwargs) : String
    Translations.t(key, **kwargs)
  end
end
