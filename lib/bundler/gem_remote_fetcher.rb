# frozen_string_literal: true

require "rubygems/remote_fetcher"

module Bundler
  # Adds support for setting custom HTTP headers when fetching gems from the
  # server.
  #
  # TODO: Get rid of this when and if gemstash only supports RubyGems versions
  # that contain https://github.com/rubygems/rubygems/commit/3db265cc20b2f813.
  class GemRemoteFetcher < Gem::RemoteFetcher
    attr_accessor :headers

    # Extracted from RubyGems 2.4.
    def fetch_http(uri, last_modified = nil, head = false, depth = 0)
      fetch_type = head ? Net::HTTP::Head : Net::HTTP::Get
      # beginning of change
      response   = request uri, fetch_type, last_modified do |req|
        headers.each {|k, v| req.add_field(k, v) } if headers
      end
      # end of change

      case response
      when Net::HTTPOK, Net::HTTPNotModified then
        response.uri = uri if response.respond_to? :uri
        head ? response : response.body
      when Net::HTTPMovedPermanently, Net::HTTPFound, Net::HTTPSeeOther,
           Net::HTTPTemporaryRedirect then
        raise FetchError.new("too many redirects", uri) if depth > 10

        require_relative "vendored_uri"
        location = Bundler::URI.parse response["Location"]

        if https?(uri) && !https?(location)
          raise FetchError.new("redirecting to non-https resource: #{location}", uri)
        end

        fetch_http(location, last_modified, head, depth + 1)
      else
        raise FetchError.new("bad response #{response.message} #{response.code}", uri)
      end
    end

    ##
    # Downloads +uri+ and returns it as a String.

    def fetch_path(uri, mtime = nil, head = false)
      uri = Bundler::URI.parse uri unless Bundler::URI::Generic === uri

      raise ArgumentError, "bad uri: #{uri}" unless uri

      unless uri.scheme
        raise ArgumentError, "uri scheme is invalid: #{uri.scheme.inspect}"
      end

      data = send "fetch_#{uri.scheme}", uri, mtime, head

      if data && !head && uri.to_s =~ /\.gz$/
        begin
          data = Gem::Util.gunzip data
        rescue Zlib::GzipFile::Error
          raise FetchError.new("server did not return a valid file", uri.to_s)
        end
      end

      data
    rescue FetchError
      raise
    rescue Timeout::Error
      raise UnknownHostError.new("timed out", uri.to_s)
    rescue IOError, SocketError, SystemCallError,
           *(OpenSSL::SSL::SSLError if defined?(OpenSSL)) => e
      if e.message =~ /getaddrinfo/
        raise UnknownHostError.new("no such name", uri.to_s)
      else
        raise FetchError.new("#{e.class}: #{e}", uri.to_s)
      end
    end
  end
end
