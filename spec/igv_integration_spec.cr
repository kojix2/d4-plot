require "./spec_helper"
require "../src/d4_plot/igv_integration"

describe D4Plot::IGVDesktop do
  it "encodes a valid desktop goto locus without allowing control characters" do
    region = D4Plot::Region.new("chr 1", 101_u32, 200_u32)
    path = D4Plot::IGVDesktop.goto_path(region)
    URI.parse("http://localhost:60151#{path}").query_params["locus"].should eq("chr 1:101-200")

    expect_raises(ArgumentError, /Invalid chromosome/) do
      D4Plot::IGVDesktop.goto_path(D4Plot::Region.new("chr1\nload", 1_u32, 2_u32))
    end
    expect_raises(ArgumentError, /Invalid genomic region/) do
      D4Plot::IGVDesktop.goto_path(D4Plot::Region.new("chr1", 0_u32, 1_u32))
    end
  end

  it "rejects invalid desktop ports before opening a connection" do
    region = D4Plot::Region.new("chr1", 1_u32, 2_u32)
    expect_raises(ArgumentError, /Invalid IGV port/) { D4Plot::IGVDesktop.goto(region, 0) }
  end

  it "keeps the bundled viewer from choosing an arbitrary multi-locus pane for Desktop" do
    viewer = File.read(File.join(__DIR__, "../assets/igv_viewer.js"))
    viewer.should contain("lociFromEvent")
    viewer.should contain("Show a single locus before sending it to IGV Desktop.")
  end
end
