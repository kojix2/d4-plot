require "./spec_helper"
require "../src/d4_plot/view_loader"
require "../src/d4_plot/plot_geometry"

private def await_stack(loader, id)
  deadline = Time.instant + 5.seconds
  loop do
    if result = loader.poll
      return result if result.request.id == id
    end
    raise "Timed out waiting for stack" if Time.instant >= deadline
    sleep 1.millisecond
  end
end

describe "Multi-track loading" do
  it "reads all internal tracks at one region with their own scaled values" do
    path = File.join(__DIR__, "fixtures/rust-multitrack.d4")
    sources = D4Plot::TrackSource.load(path)
    sources.size.should be > 1
    checks = 0
    interrupted = D4Plot::TrackSource.load(path, -> { checks += 1; checks > 1 })
    interrupted.size.should eq(1)
    chromosomes = D4Plot::TrackSource.chromosomes(sources)
    chr, size = chromosomes.first
    region = D4Plot::Region.new(chr, 1_u32, size)
    loader = D4Plot::ViewLoader.new
    begin
      id = loader.submit(sources, region, 4, true, nil, 100)
      result = await_stack(loader, id)
      result.error.should be_nil
      result.layers.map(&.source.key).should eq(sources.map(&.key))
      D4.open(path) do |file|
        result.layers.each do |sample|
          sample.error.should be_nil
          sample.view.try(&.region).should eq(region)
          expected = D4Plot::DataSampler.downsample(file.track(sample.source.name), region, 4)
          sample.view.try(&.points).should eq(expected)
        end
      end
    ensure
      loader.close
      loader.wait
    end
  end

  it "combines files, isolates a failed or absent track, and supersedes whole batches" do
    path = File.join(__DIR__, "fixtures/rust-input-10nt.d4")
    scaled_path = File.tempname("d4-stack", ".d4")
    D4.create(scaled_path, chromosomes: [D4::Chromosome.new("chr", 10)], denominator: 2.0) do |writer|
      writer.write_values("chr", 0, Array(Int32).new(10, 6))
    end
    sources = D4Plot::TrackSource.load(path) + D4Plot::TrackSource.load(scaled_path)
    sources << D4Plot::TrackSource.new("/missing.d4", "", {"chr" => 10_u32}, 1.0)
    sources << D4Plot::TrackSource.new("/absent-chromosome.d4", "", {"other" => 10_u32}, 1.0)
    loader = D4Plot::ViewLoader.new
    begin
      loader.submit(sources, D4Plot::Region.new("chr", 1_u32, 10_u32), 4, false, nil, 100)
      region = D4Plot::Region.new("chr", 4_u32, 7_u32)
      id = loader.submit(sources, region, 256, false, nil, 100)
      result = await_stack(loader, id)
      result.request.region.should eq(region)
      result.layers.size.should eq(4)
      result.layers[0].view.try { |view| view.points.map(&.[1]) }.should eq([1.0, 2.0, 2.0, 2.0])
      result.layers[1].view.try { |view| view.points.map(&.[1]) }.should eq([3.0, 3.0, 3.0, 3.0])
      result.layers[2].view.should be_nil
      result.layers[2].error.to_s.should contain("Read failed")
      result.layers[3].view.should be_nil
      result.layers[3].error.to_s.should contain("No data for chr")
      loader.submit(sources, region, 4, true, nil, 100)
      loader.cancel
      sleep 20.milliseconds
      loader.poll.should be_nil
      id = loader.submit([] of D4Plot::TrackSource, region, 4, true, nil, 100)
      await_stack(loader, id).layers.should be_empty
    ensure
      loader.close
      loader.wait
      File.delete(scaled_path)
    end
  end

  it "allows absent contigs but rejects conflicting reference lengths" do
    a = D4Plot::TrackSource.new("a.d4", "", {"chr1" => 100_u32}, 1.0)
    b = D4Plot::TrackSource.new("b.d4", "", {"chr2" => 50_u32}, 1.0)
    D4Plot::TrackSource.chromosomes([a, b]).should eq({"chr1" => 100_u32, "chr2" => 50_u32})
    c = D4Plot::TrackSource.new("c.d4", "", {"chr1" => 101_u32}, 1.0)
    expect_raises(ArgumentError, /conflicting lengths/) { D4Plot::TrackSource.chromosomes([a, c]) }
  end
end

describe D4Plot::StackGeometry do
  it "uses document coordinates for hit tests after vertical scrolling" do
    stack = D4Plot::StackGeometry.new(1000.0, 220.0, 8)
    stack.index_at(20.0).should be_nil
    stack.index_at(78.0).should eq(0)
    stack.index_at(stack.row_top(4) + 70).should eq(4)
    stack.index_at(stack.row_top(8)).should be_nil
    stack.visible?(0, stack.row_top(4), 400.0).should be_false
    stack.visible?(4, stack.row_top(4), 400.0).should be_true
    stack.plot(0).x_for(50_i64, D4Plot::Region.new("chr", 1_u32, 100_u32)).should eq(
      stack.plot(4).x_for(50_i64, D4Plot::Region.new("chr", 1_u32, 100_u32)))
    stack.height(120.0).should be > stack.row_top(8) + 120
  end
end
