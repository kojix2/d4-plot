require "./spec_helper"
require "../src/d4_plot/range_file_handler"

private record RangeHandlerResponse, status : Int32, headers : HTTP::Headers, body : String

private def with_range_file(contents : String, &)
  file = File.tempfile("d4-plot-range-file", ".data")
  path = file.path
  begin
    file.print(contents)
    file.close
    yield path
  ensure
    file.close unless file.closed?
    File.delete?(path)
  end
end

private def invoke_range_handler(handler : D4Plot::RangeFileHandler, id : String,
                                 method : String = "GET", range : String? = nil,
                                 cancelled : Bool = false) : RangeHandlerResponse
  headers = HTTP::Headers.new
  headers["Range"] = range if range
  request = HTTP::Request.new(method, "/reference/#{id}", headers)
  output = IO::Memory.new
  response = HTTP::Server::Response.new(output)
  context = HTTP::Server::Context.new(request, response)

  callback = cancelled ? -> { true } : nil
  handler.handle(context, id, callback)
  response.close
  raw = output.to_s
  separator = raw.index("\r\n\r\n") || raise "HTTP response had no header terminator"
  RangeHandlerResponse.new(response.status_code, response.headers.dup, raw.byte_slice(separator + 4))
end

describe D4Plot::RangeFileHandler do
  it "serves only opaque registered resource IDs" do
    with_range_file("0123456789") do |path|
      handler = D4Plot::RangeFileHandler.new
      id = handler.register(path, "text/plain")

      id.size.should eq(43)
      id.each_byte.all? do |byte|
        (byte >= 65_u8 && byte <= 90_u8) || (byte >= 97_u8 && byte <= 122_u8) ||
          (byte >= 48_u8 && byte <= 57_u8) || byte == 45_u8 || byte == 95_u8
      end.should be_true
      id.should_not contain(path)
      handler.registered?(id).should be_true

      response = invoke_range_handler(handler, id)
      response.status.should eq(200)
      response.body.should eq("0123456789")
      response.headers["Content-Type"].should eq("text/plain")
      response.headers["Content-Length"].should eq("10")
      response.headers["Accept-Ranges"].should eq("bytes")

      invoke_range_handler(handler, "not-a-registered-resource").status.should eq(404)
      handler.unregister(id).should be_true
      handler.registered?(id).should be_false
      invoke_range_handler(handler, id).status.should eq(404)
    end
  end

  it "serves normal, open-ended, and suffix byte ranges" do
    with_range_file("0123456789") do |path|
      handler = D4Plot::RangeFileHandler.new
      id = handler.register(path, "application/octet-stream")

      normal = invoke_range_handler(handler, id, range: "bytes=2-5")
      normal.status.should eq(206)
      normal.headers["Content-Range"].should eq("bytes 2-5/10")
      normal.headers["Content-Length"].should eq("4")
      normal.body.should eq("2345")

      open_ended = invoke_range_handler(handler, id, range: "bytes=7-")
      open_ended.status.should eq(206)
      open_ended.headers["Content-Range"].should eq("bytes 7-9/10")
      open_ended.body.should eq("789")

      suffix = invoke_range_handler(handler, id, range: "bytes=-3")
      suffix.status.should eq(206)
      suffix.headers["Content-Range"].should eq("bytes 7-9/10")
      suffix.body.should eq("789")

      clipped = invoke_range_handler(handler, id, range: "bytes=8-999")
      clipped.headers["Content-Range"].should eq("bytes 8-9/10")
      clipped.body.should eq("89")
    end
  end

  it "keeps HEAD headers while omitting its body" do
    with_range_file("0123456789") do |path|
      handler = D4Plot::RangeFileHandler.new
      id = handler.register(path, "text/plain")

      partial = invoke_range_handler(handler, id, method: "HEAD", range: "bytes=1-3")
      partial.status.should eq(206)
      partial.headers["Content-Range"].should eq("bytes 1-3/10")
      partial.headers["Content-Length"].should eq("3")
      partial.body.should be_empty

      full = invoke_range_handler(handler, id, method: "HEAD")
      full.status.should eq(200)
      full.headers["Content-Length"].should eq("10")
      full.body.should be_empty
    end
  end

  it "returns 416 with the required headers for malformed, multiple, and unsatisfiable ranges" do
    with_range_file("0123456789") do |path|
      handler = D4Plot::RangeFileHandler.new
      id = handler.register(path, "text/plain")

      ["bytes=10-10", "bytes=3-2", "bytes=-0", "bytes=0-1,3-4", "items=0-1", "bytes=999999999999999999999-"].each do |range|
        response = invoke_range_handler(handler, id, range: range)
        response.status.should eq(416)
        response.headers["Accept-Ranges"].should eq("bytes")
        response.headers["Content-Range"].should eq("bytes */10")
        response.headers["Content-Length"].should eq("0")
        response.body.should be_empty
      end
    end
  end

  it "requires a range instead of returning an oversized full resource" do
    with_range_file("0123456789") do |path|
      handler = D4Plot::RangeFileHandler.new(max_full_response_bytes: 4_i64)
      id = handler.register(path, "text/plain")

      get_response = invoke_range_handler(handler, id)
      get_response.status.should eq(413)
      get_response.headers["Accept-Ranges"].should eq("bytes")
      get_response.headers["Content-Length"].should eq("0")
      get_response.body.should be_empty

      head_response = invoke_range_handler(handler, id, method: "HEAD")
      head_response.status.should eq(413)
      head_response.body.should be_empty

      ranged = invoke_range_handler(handler, id, range: "bytes=0-1")
      ranged.status.should eq(206)
      ranged.body.should eq("01")
    end
  end

  it "uses Int64 byte offsets" do
    with_range_file("") do |path|
      offset = 4_294_967_296_i64
      File.open(path, "wb") do |file|
        file.seek(offset, IO::Seek::Set)
        file << 'Z'
      end

      handler = D4Plot::RangeFileHandler.new(max_full_response_bytes: 0_i64)
      id = handler.register(path, "application/octet-stream")
      response = invoke_range_handler(handler, id, range: "bytes=#{offset}-#{offset}")

      response.status.should eq(206)
      response.headers["Content-Range"].should eq("bytes #{offset}-#{offset}/#{offset + 1_i64}")
      response.headers["Content-Length"].should eq("1")
      response.body.should eq("Z")
    end
  end

  it "rejects a resource replaced after registration" do
    with_range_file("registered") do |path|
      with_range_file("replacement") do |replacement|
        handler = D4Plot::RangeFileHandler.new
        id = handler.register(path, "text/plain")

        File.rename(replacement, path)
        response = invoke_range_handler(handler, id)
        response.status.should eq(404)
        response.body.should be_empty
      end
    end
  end

  it "rejects an in-place resource rewrite after registration" do
    with_range_file("registered") do |path|
      handler = D4Plot::RangeFileHandler.new
      id = handler.register(path, "text/plain")

      File.write(path, "rewritten-with-a-different-size")
      response = invoke_range_handler(handler, id)
      response.status.should eq(404)
      response.body.should be_empty
    end
  end

  {% unless flag?(:win32) %}
    it "rejects a symlink substituted after registration" do
      with_range_file("registered") do |path|
        with_range_file("replacement") do |replacement|
          handler = D4Plot::RangeFileHandler.new
          id = handler.register(path, "text/plain")

          File.delete(path)
          File.symlink(replacement, path)
          response = invoke_range_handler(handler, id)
          response.status.should eq(404)
          response.body.should be_empty
        end
      end
    end
  {% end %}

  it "rejects unsafe content types and unsupported methods" do
    with_range_file("0123456789") do |path|
      handler = D4Plot::RangeFileHandler.new
      expect_raises(D4Plot::RangeFileHandler::RegistrationError) do
        handler.register(path, "text/plain\r\nX-Injected: yes")
      end

      id = handler.register(path, "text/plain")
      response = invoke_range_handler(handler, id, method: "POST")
      response.status.should eq(405)
      response.headers["Allow"].should eq("GET, HEAD")
      response.body.should be_empty
    end
  end

  it "returns a stopping response before opening a cancelled transfer" do
    with_range_file("0123456789") do |path|
      handler = D4Plot::RangeFileHandler.new
      id = handler.register(path, "text/plain")

      response = invoke_range_handler(handler, id, cancelled: true)
      response.status.should eq(503)
      response.body.should be_empty
    end
  end

  it "requires a positive bounded transfer limit" do
    expect_raises(ArgumentError, /Transfer limit/) do
      D4Plot::RangeFileHandler.new(max_concurrent_transfers: 0)
    end
  end
end
