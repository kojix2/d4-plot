require "./spec_helper"
require "../src/d4_plot/file_loader"

private def await_files(loader, id)
  deadline = Time.instant + 5.seconds
  loop do
    if result = loader.poll
      return result if result.id == id
    end
    raise "Timed out waiting for file metadata" if Time.instant >= deadline
    sleep 1.millisecond
  end
end

describe D4Plot::FileLoader do
  it "loads multiple files atomically and deduplicates existing tracks" do
    first = File.join(__DIR__, "fixtures/rust-input-10nt.d4")
    second = File.tempname("d4-file-loader", ".d4")
    D4.create(second, chromosomes: [D4::Chromosome.new("chr", 10)]) do |writer|
      writer.write_values("chr", 0, Array(Int32).new(10, 3))
    end
    loader = D4Plot::FileLoader.new
    begin
      existing = D4Plot::TrackSource.load(first)
      id = loader.submit([first, second, first], existing)
      result = await_files(loader, id)
      result.error.should be_nil
      result.sources.map(&.path).should eq([File.realpath(first), File.realpath(second)])
      result.sources.first.should eq(existing.first)

      missing = File.join(__DIR__, "fixtures/nonexistent.d4")
      id = loader.submit([second, missing], existing)
      failed = await_files(loader, id)
      failed.sources.should be_empty
      failed.error.to_s.should contain(missing)
      existing.size.should eq(1)
    ensure
      loader.close
      loader.wait
      File.delete(second)
    end
  end

  it "identifies the incompatible file without returning a partial batch" do
    source = D4Plot::TrackSource.new("old.d4", "", {"chr" => 10_u32}, 1.0)
    loader = D4Plot::FileLoader.new(->(path : String, _cancelled : Proc(Bool)) {
      [D4Plot::TrackSource.new(path, "", {"chr" => 11_u32}, 1.0)]
    })
    begin
      result = await_files(loader, loader.submit(["wrong-assembly.d4"], [source]))
      result.sources.should be_empty
      result.error.to_s.should contain("wrong-assembly.d4")
      result.error.to_s.should contain("conflicting lengths")
    ensure
      loader.close
      loader.wait
    end
  end

  it "reports progress and discards a cancelled in-flight read before accepting a new request" do
    entered = Channel(Nil).new
    release = Atomic(Bool).new(false)
    loader = D4Plot::FileLoader.new(->(path : String, cancelled : Proc(Bool)) {
      if path == "slow.d4"
        entered.send(nil)
        until cancelled.call || release.get
          sleep 1.millisecond
        end
      end
      [D4Plot::TrackSource.new(path, "", {"chr" => 10_u32}, 1.0)]
    })
    begin
      loader.submit(["slow.d4", "never-read.d4"])
      select
      when entered.receive
      when timeout(5.seconds)
        raise "File worker did not start"
      end
      progress = loader.progress || raise "File loader did not report progress"
      {progress.current, progress.total, progress.path}.should eq({1, 2, "slow.d4"})
      loader.cancel
      loader.progress.should be_nil
      loader.poll.should be_nil
      id = loader.submit(["new.d4"])
      result = await_files(loader, id)
      result.error.should be_nil
      result.sources.map(&.path).should eq(["new.d4"])
      loader.poll.should be_nil
    ensure
      entered.close
      release.set(true)
      loader.close
      loader.wait
    end
  end
end
