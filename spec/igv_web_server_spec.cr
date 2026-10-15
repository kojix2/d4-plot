require "./spec_helper"
require "../src/d4_plot/igv_web_server"
require "socket"

private def server_get(url : String, headers : HTTP::Headers? = nil) : HTTP::Client::Response
  HTTP::Client.exec("GET", url, headers)
end

private def server_post(url : String, origin : String?, body : String) : HTTP::Client::Response
  headers = HTTP::Headers{"Content-Type" => "application/json"}
  headers["Origin"] = origin if origin
  HTTP::Client.exec("POST", url, headers, body)
end

private def server_origin(url : String) : String
  uri = URI.parse(url)
  "#{uri.scheme}://#{uri.host}:#{uri.port}"
end

private def available_loopback_port : Int32
  probe = TCPServer.new("127.0.0.1", 0)
  begin
    probe.local_address.as(Socket::IPAddress).port
  ensure
    probe.close
  end
end

describe D4Plot::IGVWebServer do
  it "starts a genome browser without D4 and accepts later D4 updates" do
    server = D4Plot::IGVWebServer.new([] of D4Plot::TrackSource)
    server.start
    begin
      state = JSON.parse(server_get("#{server.url}api/state?locus=chr2:10-20").body)
      state["tracks"].as_a.should be_empty
      state["locus"].as_s.should eq("chr2:10-20")
      state["igvReference"]["genome"].as_s.should eq("hg38")
      state["referenceChoices"].as_a.map(&.["id"].as_s).should_not contain("contigs-only")

      source = D4Plot::TrackSource.load(File.join(__DIR__, "fixtures/rust-input-10nt.d4"))
      server.update(source)
      updated = JSON.parse(server_get("#{server.url}api/state").body)
      updated["tracks"].as_a.size.should eq(1)
      updated["referenceChoices"].as_a.map(&.["id"].as_s).should contain("contigs-only")

      server_post("#{server.url}api/reference", server_origin(server.url), %({"id":"contigs-only"})).status_code.should eq(200)
      server.update([] of D4Plot::TrackSource)
      empty_again = JSON.parse(server_get("#{server.url}api/state").body)
      empty_again["tracks"].as_a.should be_empty
      empty_again["referenceChoices"].as_a.map(&.["id"].as_s).should_not contain("contigs-only")
      empty_again["igvReference"]["genome"].as_s.should eq("hg38")
    ensure
      server.close
      server.wait
    end
  end

  it "releases its bound listener and D4 worker when reference initialization fails" do
    directory = File.tempname("d4-plot-invalid-reference")
    Dir.mkdir(directory)
    fasta = File.join(directory, "reference.fa")
    File.write(fasta, ">chr\nA\n")
    File.write("#{fasta}.fai", "not-a-valid-fai\n")
    source = D4Plot::TrackSource.load(File.join(__DIR__, "fixtures/rust-input-10nt.d4"))
    port = available_loopback_port
    begin
      expect_raises(D4Plot::ReferenceValidationError) do
        D4Plot::IGVWebServer.new(source, port: port, reference: D4Plot::ReferenceSpec.fasta(fasta))
      end

      # Rebinding exactly the same port proves the failed constructor did not
      # strand its listener. The successful server also owns a fresh worker.
      replacement = D4Plot::IGVWebServer.new(source, port: port)
      replacement.close
      replacement.wait
    ensure
      File.delete?("#{fasta}.fai")
      File.delete?(fasta)
      Dir.delete?(directory)
    end
  end

  it "serves a token-scoped revisioned D4 feature contract without exposing paths" do
    source = D4Plot::TrackSource.load(File.join(__DIR__, "fixtures/rust-input-10nt.d4"))
    server = D4Plot::IGVWebServer.new(source, D4Plot::Region.new("chr", 1_u32, 10_u32))
    server.start
    begin
      state_response = server_get("#{server.url}api/state")
      state_response.status_code.should eq(200)
      state_response.body.should_not contain(source.first.path)
      state = JSON.parse(state_response.body)
      state["referenceInfo"]["kind"].as_s.should eq("contigs_only")
      state["referenceInfo"]["dictionaryVerified"].as_bool.should be_true
      state["referenceChoices"].as_a.find!(&.["id"].as_s.==("contigs-only"))["label"].as_s.should eq("Contigs only")
      revision = state["revision"].as_s
      track_id = state["tracks"].as_a.first["id"].as_s
      state["igvReference"]["reference"]["format"].as_s.should eq("chromsizes")

      query = URI::Params.encode({
        "track"        => track_id,
        "chr"          => "chr",
        "start"        => "0",
        "end"          => "10",
        "bp_per_pixel" => "1",
        "revision"     => revision,
        "client"       => "browser_a",
        "navigation"   => "1",
      })
      features_response = server_get("#{server.url}api/features?#{query}")
      features_response.status_code.should eq(200)
      features = JSON.parse(features_response.body)
      features["coordinateSystem"].as_s.should eq("0-based-half-open")
      features["aggregation"].as_s.should eq("mean")
      features["features"].as_a.map(&.["value"].as_f).should eq([0.0, 0.0, 0.0, 1.0, 2.0, 2.0, 2.0, 1.0, 1.0, 0.0])

      stale = URI::Params.encode({
        "track" => track_id, "chr" => "chr", "start" => "0", "end" => "10", "bp_per_pixel" => "1",
        "revision" => "old", "client" => "browser_a", "navigation" => "2",
      })
      server_get("#{server.url}api/features?#{stale}").status_code.should eq(409)

      resource_url = state["igvReference"]["reference"]["fastaURL"].as_s
      server_get(resource_url).body.should eq("chr\t10\n")
    ensure
      server.close
      server.wait
    end
  end

  it "returns bounded chromosome-wide bins for an unindexed D4 instead of a scan-limit error" do
    path = File.tempname("d4-plot-wide-web", ".d4")
    begin
      size = D4Plot::DataSampler::DEFAULT_MAX_STREAMING_BASES + 1
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", size)],
        dictionary: D4::Dictionary.new([0_i32, 1_i32])) do |writer|
        writer.write_values("chr", 10_000_000, [1_i32])
      end
      source = D4Plot::TrackSource.load(path)
      server = D4Plot::IGVWebServer.new(source)
      server.start
      begin
        state = JSON.parse(server_get("#{server.url}api/state").body)
        query = URI::Params.encode({
          "track"        => state["tracks"].as_a.first["id"].as_s,
          "chr"          => "chr",
          "start"        => "0",
          "end"          => size.to_s,
          "bp_per_pixel" => "1",
          "revision"     => state["revision"].as_s,
          "client"       => "wide_browser",
          "navigation"   => "1",
        })
        response = server_get("#{server.url}api/features?#{query}")
        response.status_code.should eq(200)
        payload = JSON.parse(response.body)
        payload["aggregation"].as_s.should eq("sampled_mean")
        features = payload["features"].as_a
        features.size.should be <= 1_024
        features.first["start"].as_i64.should eq(0_i64)
        features.last["end"].as_i64.should eq(size)
      ensure
        server.close
        server.wait
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "requires a same-origin POST for control APIs and changes revision on a registered reference choice" do
    source = D4Plot::TrackSource.load(File.join(__DIR__, "fixtures/rust-input-10nt.d4"))
    server = D4Plot::IGVWebServer.new(source)
    server.start
    begin
      endpoint = "#{server.url}api/reference"
      server_post(endpoint, nil, %({"id":"hg38"})).status_code.should eq(403)

      changed = server_post(endpoint, server_origin(server.url), %({"id":"hg38"}))
      changed.status_code.should eq(200)
      new_revision = JSON.parse(changed.body)["revision"].as_s
      state_response = server_get("#{server.url}api/state")
      state = JSON.parse(state_response.body)
      state["revision"].as_s.should eq(new_revision)
      state["igvReference"]["genome"].as_s.should eq("hg38")
      gene_track = state["igvReference"]["genomeList"].as_a.first["tracks"].as_a.first
      gene_track["name"].as_s.should eq("GENCODE v50 genes")
      state["desktopGotoAvailable"].as_bool.should be_false
      policy = state_response.headers["Content-Security-Policy"]
      policy.should contain("connect-src 'self' https: http: blob:")
      policy.should contain("https://hgdownload.soe.ucsc.edu")
    ensure
      server.close
      server.wait
    end
  end

  it "keeps opaque track ids stable across a snapshot refresh" do
    source = D4Plot::TrackSource.load(File.join(__DIR__, "fixtures/rust-input-10nt.d4"))
    server = D4Plot::IGVWebServer.new(source)
    server.start
    begin
      first = JSON.parse(server_get("#{server.url}api/state").body)
      first_id = first["tracks"].as_a.first["id"].as_s
      server.update(source)
      second = JSON.parse(server_get("#{server.url}api/state").body)
      second["revision"].as_s.should_not eq(first["revision"].as_s)
      second["tracks"].as_a.first["id"].as_s.should eq(first_id)
    ensure
      server.close
      server.wait
    end
  end

  it "keeps compatible tracks viewable when another source has a conflicting contig length" do
    first = D4Plot::TrackSource.new("first.d4", "depth", {"chr1" => 10_u32}, 1.0)
    conflicting = D4Plot::TrackSource.new("second.d4", "depth", {"chr1" => 11_u32}, 1.0)
    server = D4Plot::IGVWebServer.new([first, conflicting])
    server.start
    begin
      state = JSON.parse(server_get("#{server.url}api/state").body)
      state["tracks"].as_a.map(&.["compatibility"].as_s).should eq(["compatible", "incompatible"])
    ensure
      server.close
      server.wait
    end
  end

  it "rejects alternate Host headers before processing a capability URL" do
    source = D4Plot::TrackSource.load(File.join(__DIR__, "fixtures/rust-input-10nt.d4"))
    server = D4Plot::IGVWebServer.new(source)
    server.start
    begin
      headers = HTTP::Headers{"Host" => "example.invalid"}
      server_get("#{server.url}api/state", headers).status_code.should eq(403)
    ensure
      server.close
      server.wait
    end
  end

  it "rejects coordinates outside Int64 instead of turning them into reader failures" do
    source = D4Plot::TrackSource.load(File.join(__DIR__, "fixtures/rust-input-10nt.d4"))
    server = D4Plot::IGVWebServer.new(source)
    server.start
    begin
      state = JSON.parse(server_get("#{server.url}api/state").body)
      track_id = state["tracks"].as_a.first["id"].as_s
      [{"start" => "0", "end" => "9223372036854775808"}, {"start" => "-9223372036854775809", "end" => "10"}].each do |coordinates|
        query = URI::Params.encode({
          "track"        => track_id,
          "chr"          => "chr",
          "start"        => coordinates["start"],
          "end"          => coordinates["end"],
          "bp_per_pixel" => "1",
          "revision"     => state["revision"].as_s,
          "client"       => "browser_a",
          "navigation"   => "1",
        })
        response = server_get("#{server.url}api/features?#{query}")
        response.status_code.should eq(400)
        JSON.parse(response.body)["error"].as_s.should eq("INVALID_INTERVAL")
      end
    ensure
      server.close
      server.wait
    end
  end

  it "serves a validated custom FASTA only through opaque range-capability routes" do
    directory = File.tempname("d4-plot-web-reference")
    Dir.mkdir(directory)
    fasta = File.join(directory, "reference.fa")
    File.write(fasta, ">chr\nACGTACGT\n")
    File.write("#{fasta}.fai", "chr\t8\t5\t8\t9\n")
    source = D4Plot::TrackSource.load(File.join(__DIR__, "fixtures/rust-input-10nt.d4"))
    server = D4Plot::IGVWebServer.new(source, reference: D4Plot::ReferenceSpec.fasta(fasta))
    server.start
    begin
      state = JSON.parse(server_get("#{server.url}api/state").body)
      reference = state["igvReference"]["reference"]
      fasta_url = reference["fastaURL"].as_s
      fasta_url.should_not contain(fasta)

      server_get(fasta_url).status_code.should eq(200)

      headers = HTTP::Headers{"Range" => "bytes=5-8"}
      fasta_response = server_get(fasta_url, headers)
      fasta_response.status_code.should eq(206)
      fasta_response.headers["Content-Range"].should eq("bytes 5-8/14")
      fasta_response.body.should eq("ACGT")

      index_response = server_get(reference["indexURL"].as_s)
      index_response.status_code.should eq(200)
      index_response.body.should eq("chr\t8\t5\t8\t9\n")
    ensure
      server.close
      server.wait
      File.delete?("#{fasta}.fai")
      File.delete?(fasta)
      Dir.delete?(directory)
    end
  end
end
