require "./spec_helper"
require "yaml"

private def flatten_catalog(node : YAML::Any, prefix = "", values = {} of String => String) : Hash(String, String)
  if mapping = node.as_h?
    mapping.each do |key, value|
      name = prefix.empty? ? key.as_s : "#{prefix}.#{key.as_s}"
      flatten_catalog(value, name, values)
    end
  else
    values[prefix] = node.as_s
  end

  values
end

private def placeholders(value : String) : Array(String)
  value.scan(/%\{([^}]+)\}/).map(&.[1]).sort!
end

describe D4Plot::Translations do
  it "loads every supported catalogue with interpolation" do
    D4Plot::Translations.setup("en")
    D4Plot.t("app.tracks", number: 2).should eq("Tracks: 2")

    I18n.with_locale("ja") do
      D4Plot.t("app.tracks", number: 2).should eq("トラック数: 2")
      D4Plot.t("app.loading", region: "chr1:1-10").should eq("chr1:1-10 を読み込み中…")
    end

    {"zh", "es", "de", "fr", "ko", "nl", "pt", "pl", "tr", "ru", "hi", "id", "ur", "vi", "he", "ar", "bn"}.each do |locale|
      I18n.with_locale(locale) do
        D4Plot.t("app.open_d4").should_not contain("missing translation")
        D4Plot.t("toolbar.display").should_not contain("missing translation")
        D4Plot.t("app.window_title", number: 2).should_not contain("%{")
      end
    end
  end

  it "keeps every locale structurally complete" do
    english = YAML.parse(File.read("config/locales/en.yml"))["en"]
    expected = flatten_catalog(english)

    D4Plot::Translations::SUPPORTED_LOCALES.each do |locale|
      catalogue = YAML.parse(File.read("config/locales/#{locale}.yml"))[locale]
      actual = flatten_catalog(catalogue)

      actual.keys.sort!.should eq(expected.keys.sort!), locale
      expected.each do |key, value|
        placeholders(actual[key]).should eq(placeholders(value)), "#{locale}: #{key}"
      end
    end
  end
end
