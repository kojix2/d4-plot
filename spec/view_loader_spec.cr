require "./spec_helper"
require "../src/d4_plot/view_loader"

private def await_view(loader, id)
  deadline = Time.instant + 5.seconds
  loop do
    if result = loader.poll
      return result if result.request.id == id
    end
    raise "Timed out waiting for view" if Time.instant >= deadline
    sleep 1.millisecond
  end
end

describe D4Plot::ViewLoader do
  it "keeps the prior annotation on replacement failure, at the requested coordinates" do
    path = File.tempname("d4-plot-retained-annotation", ".bed")
    loader = D4Plot::ViewLoader.new
    begin
      File.write(path, "chr\t0\t2\tfirst\nchr\t7\t10\tlast\n")
      sources = D4Plot::TrackSource.load(File.join(__DIR__, "fixtures/rust-input-10nt.d4"))
      first = D4Plot::Region.new("chr", 1_u32, 2_u32)
      id = loader.submit(sources, first, 4, true, path, 100)
      annotation_track = await_view(loader, id).annotation_track
      fail "annotation track is missing" unless annotation_track
      annotation_track.features.first.name.should eq("first")
      last = D4Plot::Region.new("chr", 8_u32, 10_u32)
      id = loader.submit(sources, last, 4, true, "#{path}.missing", 100, path)
      result = await_view(loader, id)
      result.error.should be_nil
      result.annotation_error.should_not be_nil
      annotation_track = result.annotation_track
      view = result.layers.first.view
      fail "annotation track is missing" unless annotation_track
      fail "D4 view is missing" unless view
      annotation_track.features.first.name.should eq("last")
      view.region.should eq(last)
      id = loader.submit(sources, last, 4, true, nil, 100)
      await_view(loader, id).annotation_track.should be_nil
    ensure
      loader.close
      loader.wait
      File.delete(path) if File.exists?(path)
    end
  end

  it "recovers from read errors and returns the latest requested region" do
    loader = D4Plot::ViewLoader.new
    begin
      region = D4Plot::Region.new("chr", 1_u32, 10_u32)
      id = loader.submit([D4Plot::TrackSource.new("/missing/d4-plot-test.d4", "", {"chr" => 10_u32}, 1.0)], region, 4, true, nil, 100)
      await_view(loader, id).layers.first.error.should_not be_nil
      path = File.join(__DIR__, "fixtures/rust-input-10nt.d4")
      loader.submit(D4Plot::TrackSource.load(path), region, 4, true, nil, 100)
      latest = D4Plot::Region.new("chr", 4_u32, 7_u32)
      id = loader.submit(D4Plot::TrackSource.load(path), latest, 256, true, nil, 100)
      result = await_view(loader, id)
      result.error.should be_nil
      view = result.layers.first.view.as(D4Plot::SampledView)
      view.region.should eq(latest)
      view.points.should eq([{4_u32, 1.0}, {5_u32, 2.0}, {6_u32, 2.0}, {7_u32, 2.0}])
      loader.cancel
    ensure
      loader.close
      loader.wait
    end
  end
end
