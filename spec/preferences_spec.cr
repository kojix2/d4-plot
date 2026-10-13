require "./spec_helper"
require "../src/d4_plot/preferences"

describe D4Plot::Preferences do
  it "persists an explicit locale" do
    File.tempfile("d4-plot-settings", ".json") do |file|
      preferences = D4Plot::Preferences.new(file.path, "ja")
      preferences.save

      loaded = D4Plot::Preferences.load(file.path)
      loaded.locale.should eq("ja")
      loaded.path.should eq(file.path)
    end
  end

  it "treats invalid or malformed preferences as system default" do
    File.tempfile("d4-plot-settings", ".json") do |file|
      File.write(file.path, %({"locale":"not-supported"}))
      D4Plot::Preferences.load(file.path).locale.should be_nil

      File.write(file.path, "not json")
      D4Plot::Preferences.load(file.path).locale.should be_nil

      File.write(file.path, "[]")
      D4Plot::Preferences.load(file.path).locale.should be_nil
    end
  end
end
