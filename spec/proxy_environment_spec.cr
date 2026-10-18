require "./spec_helper"
require "../src/d4_plot/proxy_environment"

describe D4Plot::ProxyEnvironment do
  it "uses the HTTPS proxy setting and decodes Basic credentials" do
    uri = URI.parse("https://api.genome.ucsc.edu")
    environment = {"HTTPS_PROXY" => "http://user%40lab:pass%23word@proxy.example:3128"}
    proxy = D4Plot::ProxyEnvironment.proxy_for(uri, environment) || raise "Expected a proxy"
    {proxy.host, proxy.port, proxy.username, proxy.password}.should eq({"proxy.example", 3128, "user@lab", "pass#word"})

    fallback = D4Plot::ProxyEnvironment.proxy_for(uri, {"https_proxy" => "http://proxy.example"}) || raise "Expected a proxy"
    fallback.port.should eq(80)
    preferred = D4Plot::ProxyEnvironment.proxy_for(uri, {
      "https_proxy" => "proxy.internal:8080",
      "HTTPS_PROXY" => "http://proxy.example:3128",
    }) || raise "Expected a proxy"
    {preferred.host, preferred.port}.should eq({"proxy.internal", 8080})
  end

  it "respects no_proxy hosts, suffixes, ports, and the wildcard" do
    uri = URI.parse("https://api.genome.ucsc.edu")
    environment = {"HTTPS_PROXY" => "http://proxy.example:3128", "NO_PROXY" => "example.org, genome.ucsc.edu:443"}
    D4Plot::ProxyEnvironment.proxy_for(uri, environment).should be_nil
    environment["NO_PROXY"] = "genome.ucsc.edu:8443"
    D4Plot::ProxyEnvironment.proxy_for(uri, environment).should_not be_nil
    environment["NO_PROXY"] = "*"
    D4Plot::ProxyEnvironment.proxy_for(uri, environment).should be_nil
    environment["NO_PROXY"] = "example.org"
    environment["no_proxy"] = ".genome.ucsc.edu."
    D4Plot::ProxyEnvironment.proxy_for(uri, environment).should be_nil
    environment["no_proxy"] = "api.genome.ucsc.edu:invalid"
    D4Plot::ProxyEnvironment.proxy_for(uri, environment).should_not be_nil
  end

  it "supports IPv4 CIDR and bracketed IPv6 no_proxy entries" do
    environment = {"HTTPS_PROXY" => "http://proxy.example:3128", "NO_PROXY" => "10.0.0.0/8, [::1]:443"}
    D4Plot::ProxyEnvironment.proxy_for(URI.parse("https://10.1.2.3"), environment).should be_nil
    D4Plot::ProxyEnvironment.proxy_for(URI.parse("https://[::1]"), environment).should be_nil
    environment["NO_PROXY"] = "10.0.0.0/invalid, [::1]:8443"
    D4Plot::ProxyEnvironment.proxy_for(URI.parse("https://10.1.2.3"), environment).should_not be_nil
    D4Plot::ProxyEnvironment.proxy_for(URI.parse("https://[::1]"), environment).should_not be_nil
  end

  it "rejects unsupported proxy URLs" do
    expect_raises(ArgumentError, /HTTPS_PROXY/) do
      D4Plot::ProxyEnvironment.proxy_for(URI.parse("https://api.genome.ucsc.edu"), {"HTTPS_PROXY" => "https://proxy.example:8443"})
    end
  end
end
