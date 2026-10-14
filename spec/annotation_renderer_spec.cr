require "./spec_helper"
require "../src/d4_plot/annotation_renderer"

describe D4Plot::AnnotationLaneAllocator do
  it "keeps only visible lanes for a dense annotation region" do
    lanes = D4Plot::AnnotationLaneAllocator.new(4)
    overlapping = D4Plot::AnnotationFeature.new("chr1", 1_u32, 10_u32, "gene", nil, nil)

    assignments = Array.new(5_000) { lanes.assign(overlapping) }
    assignments.first(4).should eq([0, 1, 2, 3])
    assignments[4..].all?(&.nil?).should be_true
    lanes.lane_count.should eq(4)

    later = D4Plot::AnnotationFeature.new("chr1", 11_u32, 20_u32, "gene", nil, nil)
    lanes.assign(later).should eq(0)
    lanes.lane_count.should eq(4)
  end

  it "returns no lane when the annotation area has no room" do
    lanes = D4Plot::AnnotationLaneAllocator.new(0)
    feature = D4Plot::AnnotationFeature.new("chr1", 1_u32, 10_u32, "gene", nil, nil)
    lanes.assign(feature).should be_nil
    lanes.lane_count.should eq(0)
  end
end
