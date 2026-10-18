require "http_proxy"
require "socket"
require "uri"

module D4Plot
  # Translates the environment's proxy settings for HTTPS public APIs into the
  # explicit proxy client used by HTTP::Client.
  module ProxyEnvironment
    def self.proxy_for(uri : URI, environment : Hash(String, String) = ENV.to_h) : HTTP::Proxy::Client?
      host = uri.host || raise ArgumentError.new("Public annotation URL has no host")
      bypass = setting(environment, "no_proxy", "NO_PROXY")
      return if no_proxy?(host, uri.port || 443, bypass)

      value = setting(environment, "https_proxy", "HTTPS_PROXY")
      return if value.empty?
      proxy_from_url(value)
    end

    private def self.setting(environment : Hash(String, String), lowercase : String, uppercase : String) : String
      value = environment[lowercase]?.to_s.strip
      value.empty? ? environment[uppercase]?.to_s.strip : value
    end

    private def self.proxy_from_url(value : String) : HTTP::Proxy::Client
      value = "http://#{value}" unless value.includes?("://")
      uri = URI.parse(value)
      host = uri.host || raise ArgumentError.new("HTTPS_PROXY must use an http:// proxy URL or host:port")
      if uri.scheme != "http" || host.empty? || !uri.path.in?({"", "/"}) || uri.query || uri.fragment
        raise ArgumentError.new("HTTPS_PROXY must use an http:// proxy URL or host:port")
      end

      HTTP::Proxy::Client.new(host, uri.port || 80,
        username: uri.user.try { |user| URI.decode(user) },
        password: uri.password.try { |password| URI.decode(password) })
    rescue URI::Error
      raise ArgumentError.new("Invalid HTTPS_PROXY URL")
    end

    private def self.no_proxy?(host : String, port : Int32, value : String) : Bool
      host = normalize_host(host)
      value.split(',').any? do |entry|
        pattern = entry.strip.downcase
        next true if pattern == "*"
        domain, requested_port = split_entry(pattern)
        next false if requested_port && requested_port != port

        domain = normalize_host(domain)
        next ipv4_cidr_matches?(host, domain) if domain.includes?('/')
        !domain.empty? && (host == domain || host.ends_with?(".#{domain}"))
      end
    end

    private def self.split_entry(entry : String) : {String, Int32?}
      if entry.starts_with?('[')
        if bracket_end = entry.index(']')
          host = entry[1...bracket_end]
          rest = entry[(bracket_end + 1)..]
          return {host, parse_port(rest[1..])} if rest.starts_with?(':')
          return {host, nil} if rest.empty?
        end
      elsif entry.count(':') == 1
        host, port = entry.split(':', 2)
        return {host, parse_port(port)}
      end
      {entry, nil}
    end

    private def self.parse_port(value : String) : Int32
      port = value.to_i?
      port && (0..65_535).includes?(port) ? port : -1
    end

    private def self.normalize_host(host : String) : String
      host = host.downcase
      host = host[1...-1] if host.starts_with?('[') && host.ends_with?(']')
      host.chomp(".").lchop('.')
    end

    private def self.ipv4_cidr_matches?(host : String, cidr : String) : Bool
      network, prefix = cidr.split('/', 2)
      bits = prefix.to_i?
      return false unless bits && (0..32).includes?(bits)
      host_address = ipv4_to_u32(host)
      network_address = ipv4_to_u32(network)
      return false unless host_address && network_address

      mask = bits == 0 ? 0_u32 : UInt32::MAX << (32 - bits)
      (host_address & mask) == (network_address & mask)
    end

    private def self.ipv4_to_u32(host : String) : UInt32?
      fields = Socket::IPAddress.parse_v4_fields?(host)
      return unless fields
      fields.reduce(0_u32) { |value, field| (value << 8) | field.to_u32 }
    end
  end
end
