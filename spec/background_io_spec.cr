require "./spec_helper"
require "http/server"
require "../src/d4_plot/igv_integration"
require "../src/d4_plot/preferences"
require "../src/d4_plot/ui_runtime"

describe D4Plot::BackgroundIO do
  it "sends an IGV Desktop request from its background context" do
    server = HTTP::Server.new(&.response.print("OK"))
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    io = D4Plot::BackgroundIO.new
    outcome = Channel(String | Exception).new(1)
    begin
      io.submit(-> {
        begin
          D4Plot::IGVDesktop.goto(D4Plot::Region.new("chr1", 1_u32, 2_u32), address.port)
          outcome.send("ok")
        rescue ex
          outcome.send(ex)
        end
      }) { }
      outcome.receive.should eq("ok")
    ensure
      io.close
      io.wait
      server.close
    end
  end

  it "serializes snapshots and drains accepted writes on close" do
    path = File.tempname("d4-background-settings", ".json")
    io = D4Plot::BackgroundIO.new
    gate = Channel(Nil).new
    first = Channel(String).new(1)
    begin
      io.submit(-> { gate.receive }) { }
      preferences = D4Plot::Preferences.new(path)
      preferences.settings.h_lines = [1.0]
      preferences.save_async(io) { }
      io.submit(-> { first.send(File.read(path)) }) { }
      preferences.settings.h_lines << 2.0
      preferences.sidebar_visible = false
      preferences.save_async(io) { }
      io.close
      gate.send(nil)
      io.wait
      JSON.parse(first.receive)["display"]["h_lines"].as_a.map(&.as_f).should eq([1.0])
      saved = D4Plot::Preferences.load(path)
      saved.settings.h_lines.should eq([1.0, 2.0])
      saved.sidebar_visible?.should be_false
    ensure
      io.close
      File.delete(path) if File.exists?(path)
    end
  end

  it "reports a failed save on the polling thread and continues processing" do
    io = D4Plot::BackgroundIO.new
    owner = Thread.current
    completed = Channel(Nil).new(1)
    events = [] of String
    File.tempfile("d4-not-a-directory") do |file|
      preferences = D4Plot::Preferences.new(File.join(file.path, "settings.json"))
      preferences.save_async(io) do |error|
        Thread.current.should be(owner)
        error.should be_a(File::Error)
        events << "failed"
      end
      io.submit(-> { completed.send(nil) }) { events << "continued" }
      completed.receive
      owner = Thread.current
      events.should be_empty
      until events.size == 2
        io.poll
        Thread.yield
      end
      events.should eq(["failed", "continued"])
    ensure
      io.close
      io.wait
    end
  end
end

describe D4Plot::UIRuntime do
  it "loads on another thread without moving the caller and propagates errors" do
    owner = Thread.current
    D4Plot::UIRuntime.load do
      sleep 20.milliseconds
      Thread.current == owner
    end.should be_false
    Thread.current.should be(owner)
    expect_raises(Exception, "startup failed") do
      D4Plot::UIRuntime.load { raise "startup failed" }
    end
    Thread.current.should be(owner)
  end
end
