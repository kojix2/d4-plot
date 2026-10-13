require "./spec_helper"
require "../src/d4_plot/region"
require "../src/d4_plot/plot_geometry"

describe "Pan preview coordinates" do
  it "keeps data at its genomic coordinate while the viewport moves" do
    loaded = D4Plot::Region.new("chr1", 101_u32, 200_u32)
    preview = loaded.pan(0.25, 1000_u32)
    preview.to_s.should eq("chr1:126-225")
    layout = D4Plot::PlotGeometry.new(1120.0, 600.0, 0.0)
    layout.x_for(125_i64, preview).should eq(layout.left)
    layout.x_for(200_i64, preview).should eq(layout.left + layout.width * 0.75)
    layout.x_for(100_i64, preview).should be < layout.left
  end

  it "preserves the span at both chromosome edges" do
    region = D4Plot::Region.new("chr1", 101_u32, 200_u32)
    region.pan(-2.0, 1000_u32).to_s.should eq("chr1:1-100")
    region.pan(20.0, 1000_u32).to_s.should eq("chr1:901-1000")
    region.pan(0.0, 1000_u32).should eq(region)
  end

  it "supports a single-base and whole-chromosome viewport" do
    D4Plot::Region.new("chr1", 5_u32, 5_u32).pan(1.0, 10_u32).to_s.should eq("chr1:6-6")
    D4Plot::Region.new("chr1", 1_u32, 10_u32).pan(0.5, 10_u32).to_s.should eq("chr1:1-10")
  end
end
