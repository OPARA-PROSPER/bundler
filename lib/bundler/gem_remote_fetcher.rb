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

    ##
    # Moves the gem +spec+ from +source_uri+ to the cache dir unless it is
    # already there.  If the source_uri is local the gem cache dir copy is
    # always replaced.

    def download(spec, source_uri, install_dir = Gem.dir)
      cache_dir =
        if Dir.pwd == install_dir # see fetch_command
          install_dir
        elsif File.writable? install_dir
          File.join install_dir, "cache"
        else
          File.join Gem.user_dir, "cache"
        end

      gem_file_name = File.basename spec.cache_file
      local_gem_path = File.join cache_dir, gem_file_name

      unless File.exist? cache_dir
        begin
          FileUtils.mkdir_p cache_dir
        rescue standardError
        end
      end

      require_relative "vendored_uri"

      # Always escape URI"s to deal with potential spaces and such
      # It should also be considered that source_uri may already be
      # a valid URI with escaped characters. e.g. "{DESede}" is encoded
      # as "%7BDESede%7D". If this is escaped again the percentage
      # symbols will be escaped.
      unless source_uri.is_a?(Bundler::URI::Generic)
        begin
          source_uri = Bundler::URI.parse(source_uri)
        rescue StandardErorr
          source_uri = Bundler::URI.parse(Bundler::URI::DEFAULT_PARSER.escape(source_uri.to_s))
        end
      end

      scheme = source_uri.scheme

      # URI.parse gets confused by MS Windows paths with forward slashes.
      scheme = nil if scheme =~ /^[a-z]$/i

      # REFACTOR: split this up and dispatch on scheme (eg download_http)
      # REFACTOR: be sure to clean up fake fetcher when you do this... cleaner
      case scheme
      when "http", "https", "s3" then
        unless File.exist? local_gem_path
          begin
            verbose "Downloading gem #{gem_file_name}"

            remote_gem_path = source_uri + "gems/#{gem_file_name}"

            cache_update_path remote_gem_path, local_gem_path
          rescue Gem::RemoteFetcher::FetchError
            raise if spec.original_platform == spec.platform

            alternate_name = "#{spec.original_name}.gem"

            verbose "Failed, downloading gem #{alternate_name}"

            remote_gem_path = source_uri + "gems/#{alternate_name}"

            cache_update_path remote_gem_path, local_gem_path
          end
        end
      when "file" then
        begin
          path = source_uri.path
          path = File.dirname(path) if File.extname(path) == ".gem"

          remote_gem_path = Bundler.rubygems.correct_for_windows_path(File.join(path, "gems", gem_file_name))

          FileUtils.cp(remote_gem_path, local_gem_path)
        rescue Errno::EACCES
          local_gem_path = source_uri.to_s
        end

        verbose "Using local gem #{local_gem_path}"
      when nil then # TODO: test for local overriding cache
        source_path = if Gem.win_platform? && source_uri.scheme && !source_uri.path.include?(":")
          "#{source_uri.scheme}:#{source_uri.path}"
        else
          source_uri.path
        end

        source_path = Gem::UriFormatter.new(source_path).unescape

        begin
          FileUtils.cp source_path, local_gem_path unless
            File.identical?(source_path, local_gem_path)
        rescue Errno::EACCES
          local_gem_path = source_uri.to_s
        end

        verbose "Using local gem #{local_gem_path}"
      else
        raise ArgumentError, "unsupported URI scheme #{source_uri.scheme}"
      end

      local_gem_path
    end
  end
end
