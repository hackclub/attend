# Reverse proxy onto the Mintlify-hosted API reference.
#
# Mintlify serves the docs from <subdomain>.mintlifysite.com. We proxy them
# under attend.hackclub.com/docs rather than giving them their own host so they
# stay behind the same admin gate the Scalar reference had: Mintlify's own auth
# is a paid tier, and the API surface has never been public.
#
# The header contract is theirs (https://mintlify.com/docs/deploy/reverse-proxy):
# send Origin, X-Forwarded-For, X-Forwarded-Proto, X-Real-IP and User-Agent, and
# do *not* forward Host — their edge routes on it, so a forwarded
# attend.hackclub.com would land on the wrong site (or nothing at all).
module Mintlify
  class Proxy
    # Raised when MINTLIFY_DOCS_HOST is unset. Callers check `configured?`
    # first; this only fires if something builds a proxy anyway.
    class NotConfigured < StandardError; end

    # Any failure reaching Mintlify — DNS, TLS, connect, read timeout. Wrapped
    # so the controller doesn't have to know we use Faraday.
    class Unavailable < StandardError; end

    Result = Struct.new(:status, :headers, :body, keyword_init: true)

    # Copied back to the browser, lowercased as Faraday hands them to us.
    #
    # Everything else is dropped on purpose. Connection/Transfer-Encoding are
    # hop-by-hop and meaningless downstream. Content-Length and
    # Content-Encoding describe the *upstream* body: Net::HTTP has already
    # gunzipped it by the time we see it, so forwarding them would describe
    # bytes we are not sending and the browser would fail to parse the page.
    PASSTHROUGH_RESPONSE_HEADERS = %w[
      content-type
      content-security-policy
      etag
      last-modified
      link
      location
      vary
      x-robots-tag
    ].freeze

    # Forwarded from the browser when present. Deliberately absent: Cookie
    # (the docs are same-origin with the app, so the browser attaches Attend's
    # session cookie to every /docs request and forwarding it would hand our
    # session to a third party) and Accept-Encoding (Net::HTTP negotiates its
    # own and decompresses for us).
    FORWARDED_REQUEST_HEADERS = {
      "Accept" => "HTTP_ACCEPT",
      "Accept-Language" => "HTTP_ACCEPT_LANGUAGE",
      "If-Modified-Since" => "HTTP_IF_MODIFIED_SINCE",
      "If-None-Match" => "HTTP_IF_NONE_MATCH"
    }.freeze

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 15

    class << self
      def host
        ENV["MINTLIFY_DOCS_HOST"].presence
      end

      def configured?
        host.present?
      end
    end

    def initialize(host: self.class.host)
      raise NotConfigured, "MINTLIFY_DOCS_HOST is not set" if host.blank?

      @host = host
    end

    # `upstream_path` is the full path to fetch, leading slash included. We
    # send the same path we were called on: Mintlify is configured with /docs
    # as its base path, so it already builds every link and asset URL under
    # that prefix and there is nothing to rewrite.
    def call(request, upstream_path)
      response = connection.get(target_for(request, upstream_path)) do |req|
        apply_headers(req, request)
      end

      Result.new(
        status: response.status,
        headers: response_headers(response),
        body: response.body.to_s
      )
    rescue Faraday::Error => e
      raise Unavailable, "#{e.class}: #{e.message}"
    end

    private

    def target_for(request, upstream_path)
      return upstream_path if request.query_string.blank?

      "#{upstream_path}?#{request.query_string}"
    end

    def apply_headers(req, request)
      FORWARDED_REQUEST_HEADERS.each do |name, rack_key|
        value = request.get_header(rack_key)
        req.headers[name] = value if value.present?
      end

      req.headers["Origin"] = "https://#{@host}"
      req.headers["User-Agent"] = request.user_agent.to_s
      req.headers["X-Real-IP"] = request.remote_ip
      req.headers["X-Forwarded-Proto"] = request.scheme
      req.headers["X-Forwarded-For"] = forwarded_for(request)
    end

    def forwarded_for(request)
      [ request.get_header("HTTP_X_FORWARDED_FOR"), request.remote_ip ].compact_blank.join(", ")
    end

    def response_headers(response)
      headers = response.headers.to_h.transform_keys(&:downcase)

      PASSTHROUGH_RESPONSE_HEADERS.filter_map { |name|
        value = headers[name]
        next if value.blank?

        [ name, name == "location" ? rewrite_location(value) : value ]
      }.to_h
    end

    # A redirect upstream points at the Mintlify host. Left alone it would walk
    # the browser straight off attend.hackclub.com and out from behind the admin
    # gate, so send it back to the same path on our own origin instead.
    def rewrite_location(location)
      uri = URI.parse(location)
      return location unless uri.host == @host

      [ uri.path, uri.query ].compact_blank.join("?")
    rescue URI::InvalidURIError
      location
    end

    def connection
      @connection ||= Faraday.new(url: "https://#{@host}") do |f|
        f.options.open_timeout = OPEN_TIMEOUT
        f.options.timeout = READ_TIMEOUT
        # No :raise_error and no :follow_redirects — upstream statuses are
        # passed through verbatim so Mintlify's own 404 page renders, and a
        # 308 is the browser's to follow, not ours.
        f.adapter Faraday.default_adapter
      end
    end
  end
end
