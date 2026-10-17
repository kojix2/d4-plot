require "./spec_helper"
require "../src/d4_plot/view_loader"
require "./support/indexed_annotation"

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
  it "repeatedly reads indexed GTF in the isolated worker without subprocesses" do
    contents = "chr\tref\tgene\t1\t2\t.\t+\t.\tgene_name \"first\";\n" +
               "chr\tref\texon\t8\t10\t.\t+\t.\tgene_name \"last\";\n"
    AnnotationFixtures.with_indexed(contents, ".gtf", :gff) do |path|
      loader = D4Plot::ViewLoader.new
      begin
        sources = D4Plot::TrackSource.load(File.join(__DIR__, "fixtures/rust-input-10nt.d4"))
        20.times do |i|
          region = i.even? ? D4Plot::Region.new("chr", 1_u32, 2_u32) : D4Plot::Region.new("chr", 8_u32, 10_u32)
          id = loader.submit(sources, region, 4, true, path, 100)
          result = await_view(loader, id)
          result.error.should be_nil
          result.annotation_error.should be_nil
          track = result.annotation_track || raise "Indexed annotation track is missing"
          track.features.map(&.name).should eq([i.even? ? "first" : "last"])
        end
      ensure
        loader.close
        loader.wait
      end
    end
  end

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

  {% unless flag?(:win32) %}
    it "reopens a D4 file after an atomic same-path replacement" do
      path = File.tempname("d4-plot-replaced-view", ".d4")
      replacement = "#{path}.replacement"
      timestamp = Time.utc(2020, 1, 1)
      loader = D4Plot::ViewLoader.new
      begin
        D4.create(path, chromosomes: [D4::Chromosome.new("chr", 4)]) do |writer|
          writer.write_values("chr", 0, [1_i32, 1_i32, 1_i32, 1_i32])
        end
        File.utime(timestamp, timestamp, path)
        sources = D4Plot::TrackSource.load(path)
        region = D4Plot::Region.new("chr", 1_u32, 4_u32)
        first = await_view(loader, loader.submit(sources, region, 4, true, nil, 100))
        first.layers.first.view.not_nil!.points.first[1].should eq(1.0)

        D4.create(replacement, chromosomes: [D4::Chromosome.new("chr", 4)]) do |writer|
          writer.write_values("chr", 0, [9_i32, 9_i32, 9_i32, 9_i32])
        end
        File.size(replacement).should eq(File.size(path))
        File.utime(timestamp, timestamp, replacement)
        File.rename(replacement, path)

        second = await_view(loader, loader.submit(sources, region, 4, true, nil, 100))
        second.layers.first.view.not_nil!.points.first[1].should eq(9.0)
      ensure
        loader.close
        loader.wait
        File.delete?(replacement)
        File.delete?(path)
      end
    end

    it "reloads an annotation after an atomic same-path replacement" do
      path = File.tempname("d4-plot-replaced-annotation", ".bed")
      replacement = "#{path}.replacement"
      timestamp = Time.utc(2020, 1, 1)
      loader = D4Plot::ViewLoader.new
      begin
        File.write(path, "chr\t0\t2\tfirst\n")
        File.utime(timestamp, timestamp, path)
        sources = D4Plot::TrackSource.load(File.join(__DIR__, "fixtures/rust-input-10nt.d4"))
        region = D4Plot::Region.new("chr", 1_u32, 2_u32)
        first = await_view(loader, loader.submit(sources, region, 4, true, path, 100))
        first.annotation_track.not_nil!.features.first.name.should eq("first")

        File.write(replacement, "chr\t0\t2\tother\n")
        File.size(replacement).should eq(File.size(path))
        File.utime(timestamp, timestamp, replacement)
        File.rename(replacement, path)

        second = await_view(loader, loader.submit(sources, region, 4, true, path, 100))
        second.annotation_track.not_nil!.features.first.name.should eq("other")
      ensure
        loader.close
        loader.wait
        File.delete?(replacement)
        File.delete?(path)
      end
    end

    it "reloads an annotation after an in-place same-millisecond update" do
      path = File.tempname("d4-plot-updated-annotation", ".bed")
      initial_time = Time.unix_ns(1_600_000_000_000_100_000_i128)
      updated_time = Time.unix_ns(1_600_000_000_000_900_000_i128)
      loader = D4Plot::ViewLoader.new
      begin
        File.write(path, "chr\t0\t2\tfirst\n")
        File.utime(initial_time, initial_time, path)
        initial_info = File.info(path)
        sources = D4Plot::TrackSource.load(File.join(__DIR__, "fixtures/rust-input-10nt.d4"))
        region = D4Plot::Region.new("chr", 1_u32, 2_u32)
        first = await_view(loader, loader.submit(sources, region, 4, true, path, 100))
        first.annotation_track.not_nil!.features.first.name.should eq("first")

        # Writing an existing file preserves its inode. The contents and
        # timestamp differ only below millisecond precision.
        File.write(path, "chr\t0\t2\tother\n")
        File.utime(updated_time, updated_time, path)
        updated_info = File.info(path)
        initial_info.same_file?(updated_info).should be_true
        initial_info.size.should eq(updated_info.size)
        initial_info.modification_time.to_unix_ms.should eq(updated_info.modification_time.to_unix_ms)
        initial_info.modification_time.to_unix_ns.should_not eq(updated_info.modification_time.to_unix_ns)

        second = await_view(loader, loader.submit(sources, region, 4, true, path, 100))
        second.annotation_track.not_nil!.features.first.name.should eq("other")
      ensure
        loader.close
        loader.wait
        File.delete?(path)
      end
    end
  {% end %}
end
