require "./spec_helper"
require "../src/d4_plot/natural_sort"

describe D4Plot::NaturalSort do
  it "orders embedded digit runs by numeric magnitude" do
    values = %w[sample10 sample02 sample1 sample001 sample2]
    values.sort! { |left, right| D4Plot::NaturalSort.compare(left, right) }
    values.should eq(%w[sample1 sample001 sample2 sample02 sample10])
  end

  it "compares text case-insensitively before using spelling as a tie-breaker" do
    values = %w[trackB2 Trackb10 trackb1]
    values.sort! { |left, right| D4Plot::NaturalSort.compare(left, right) }
    values.should eq(%w[trackb1 trackB2 Trackb10])

    D4Plot::NaturalSort.compare("Track2", "track2").should_not eq(0)
  end

  it "supports digit runs larger than fixed-width integers" do
    smaller = "track999999999999999999999999999999"
    larger = "track1000000000000000000000000000000"
    D4Plot::NaturalSort.compare(smaller, larger).should be < 0
  end
end
