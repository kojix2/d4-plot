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

  it "restores display and layout preferences without initializing the GUI" do
    File.tempfile("d4-plot-settings", ".json") do |file|
      preferences = D4Plot::Preferences.new(file.path, "ja")
      settings = preferences.settings
      settings.toolbar_display_mode = UIng::Toolbar::DisplayMode::TextOnly
      settings.plot_color = {0.1, 0.2, 0.3, 0.8}
      settings.point_count = 512
      settings.annotation_feature_limit = 123
      settings.y_min = -5.0
      settings.y_max = 25.0
      settings.y_axis_from_zero = false
      settings.h_lines = [1.0, 2.0]
      preferences.height_index = 2
      preferences.shared_y = true
      preferences.sidebar_visible = false
      preferences.save
      loaded = D4Plot::Preferences.load(file.path)
      loaded.locale.should eq("ja")
      loaded.settings.to_json.should eq(settings.to_json)
      loaded.height_index.should eq(2)
      loaded.shared_y?.should be_true
      loaded.sidebar_visible?.should be_false
    end
  end

  it "keeps sensible defaults for old files and validates individual display fields" do
    File.tempfile("d4-plot-settings", ".json") do |file|
      File.write(file.path, %({"locale":"ja"}))
      old = D4Plot::Preferences.load(file.path)
      old.settings.toolbar_display_mode.should eq(UIng::Toolbar::DisplayMode::IconAndTextVertical)
      old.height_index.should eq(1)
      old.sidebar_visible?.should be_true

      File.write(file.path, %({"locale":"ja","track_height":99,"shared_y":"yes","display":{"point_count":-1,"annotation_feature_limit":100,"toolbar_display_mode":"invalid","plot_color":[1,2,3,4],"y_min":5,"y_max":1,"h_lines":[2,"bad",1,2]}}))
      loaded = D4Plot::Preferences.load(file.path)
      loaded.locale.should eq("ja")
      loaded.settings.point_count.should eq(old.settings.point_count)
      loaded.settings.annotation_feature_limit.should eq(100)
      loaded.settings.plot_color.should eq(old.settings.plot_color)
      loaded.settings.y_min.should be_nil
      loaded.settings.y_max.should be_nil
      loaded.settings.h_lines.should eq([1.0, 2.0])
      loaded.height_index.should eq(1)
      loaded.shared_y?.should be_false
    end
  end
end
