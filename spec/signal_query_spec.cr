require "./spec_helper"
require "../src/d4_plot/signal_query"

describe D4Plot::BinLayout do
  it "uses chromosome-origin fixed bins and caps the result count" do
    layout = D4Plot::BinLayout.for_viewport(5_i64, 26_i64, 4.0, 30_i64, 8)
    layout.width.should eq(4_i64)
    layout.bins.should eq([
      D4Plot::BinRange.new(4_i64, 8_i64),
      D4Plot::BinRange.new(8_i64, 12_i64),
      D4Plot::BinRange.new(12_i64, 16_i64),
      D4Plot::BinRange.new(16_i64, 20_i64),
      D4Plot::BinRange.new(20_i64, 24_i64),
      D4Plot::BinRange.new(24_i64, 28_i64),
    ])

    capped = D4Plot::BinLayout.for_viewport(0_i64, 100_i64, 1.0, 100_i64, 4)
    capped.bins.size.should eq(3)
    capped.width.should eq(34_i64)

    aligned = D4Plot::BinLayout.for_viewport(5_i64, 26_i64, 4.0, 30_i64, alignment: 8_i64)
    aligned.width.should eq(8_i64)
    aligned.bins.should eq([
      D4Plot::BinRange.new(0_i64, 8_i64),
      D4Plot::BinRange.new(8_i64, 16_i64),
      D4Plot::BinRange.new(16_i64, 24_i64),
      D4Plot::BinRange.new(24_i64, 30_i64),
    ])
  end
end

describe D4Plot::SignalQuery do
  it "owns a reusable D4 reader and caches exact fixed-grid results" do
    source = D4Plot::TrackSource.load(File.join(__DIR__, "fixtures/rust-input-10nt.d4")).first
    layout = D4Plot::BinLayout.for_viewport(0_i64, 10_i64, 1.0, 10_i64)
    query = D4Plot::SignalQuery.new
    begin
      first = query.query(source, "chr", layout, "reference-r1", "browser-a", 1_i64)
      first.cache_hit.should be_false
      first.bins.map(&.value).should eq([0.0, 0.0, 0.0, 1.0, 2.0, 2.0, 2.0, 1.0, 1.0, 0.0])

      cached = query.query(source, "chr", layout, "reference-r1", "browser-a", 1_i64)
      cached.cache_hit.should be_true
      cached.bins.should eq(first.bins)
    ensure
      query.close
      query.wait
    end
  end

  it "rejects requests outside the registered D4 chromosome" do
    source = D4Plot::TrackSource.load(File.join(__DIR__, "fixtures/rust-input-10nt.d4")).first
    layout = D4Plot::BinLayout.for_viewport(0_i64, 10_i64, 1.0, 10_i64)
    query = D4Plot::SignalQuery.new
    begin
      expect_raises(ArgumentError, /D4 chromosome/) do
        query.query(source, "missing", layout, "reference-r1", "browser-a", 1_i64)
      end
    ensure
      query.close
      query.wait
    end
  end

  it "cancels a request from an invalidated web-session revision" do
    source = D4Plot::TrackSource.load(File.join(__DIR__, "fixtures/rust-input-10nt.d4")).first
    layout = D4Plot::BinLayout.for_viewport(0_i64, 10_i64, 1.0, 10_i64)
    query = D4Plot::SignalQuery.new
    begin
      query.activate_revision("reference-r2")
      expect_raises(D4Plot::SignalQueryCancelled, /superseded/) do
        query.query(source, "chr", layout, "reference-r1", "browser-a", 1_i64)
      end
    ensure
      query.close
      query.wait
    end
  end

  it "reuses source data cache across an immutable session replacement" do
    source = D4Plot::TrackSource.load(File.join(__DIR__, "fixtures/rust-input-10nt.d4")).first
    layout = D4Plot::BinLayout.for_viewport(0_i64, 10_i64, 1.0, 10_i64)
    query = D4Plot::SignalQuery.new
    begin
      query.activate_revision("reference-r1")
      first = query.query(source, "chr", layout, "reference-r1", "browser-a", 1_i64)
      first.cache_hit.should be_false

      query.activate_revision("reference-r2")
      second = query.query(source, "chr", layout, "reference-r2", "browser-a", 2_i64)
      second.cache_hit.should be_true
      second.bins.should eq(first.bins)
    ensure
      query.close
      query.wait
    end
  end

  {% unless flag?(:win32) %}
    it "invalidates an evicted file's cache after an atomic same-stat replacement" do
      directory = File.tempname("d4-plot-signal-replacement")
      Dir.mkdir(directory)
      first_path = File.join(directory, "first.d4")
      second_path = File.join(directory, "second.d4")
      replacement_path = File.join(directory, "replacement.d4")
      fixture = File.join(__DIR__, "fixtures/rust-input-10nt.d4")
      timestamp = Time.utc(2020, 1, 1)
      File.copy(fixture, first_path)
      File.copy(fixture, second_path)
      File.utime(timestamp, timestamp, first_path)
      first = D4Plot::TrackSource.load(first_path).first
      second = D4Plot::TrackSource.load(second_path).first
      layout = D4Plot::BinLayout.for_viewport(0_i64, 10_i64, 1.0, 10_i64)
      query = D4Plot::SignalQuery.new(max_open_files: 1)
      begin
        query.activate_revision("reference-r1")
        query.query(first, "chr", layout, "reference-r1", "browser-a", 1_i64).cache_hit.should be_false
        # A distinct source evicts first_path's D4 descriptor but should not
        # evict its result cache yet.
        query.query(second, "chr", layout, "reference-r1", "browser-a", 1_i64)

        File.copy(fixture, replacement_path)
        File.utime(timestamp, timestamp, replacement_path)
        File.rename(replacement_path, first_path)

        # Path, size, and mtime are intentionally unchanged. Only the file
        # identity proves this is a new source, so the old cache must miss.
        query.query(first, "chr", layout, "reference-r1", "browser-a", 2_i64).cache_hit.should be_false
      ensure
        query.close
        query.wait
        File.delete?(replacement_path)
        File.delete?(second_path)
        File.delete?(first_path)
        Dir.delete?(directory)
      end
    end
  {% end %}
end
