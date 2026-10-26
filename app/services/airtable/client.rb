require "faraday/retry"

module Airtable
  class Client
    BASE_URL = "https://api.airtable.com/v0".freeze

    # The OAuth connection wins over a pasted personal access token; the app-wide
    # credentials are a last resort for events configured neither way.
    def self.for_event(event)
      api_key = event.airtable_connection&.fresh_access_token! ||
        event.airtable_api_key.presence ||
        Rails.application.credentials.dig(:airtable, :api_key)
      base_id = event.airtable_base_id.presence || Rails.application.credentials.dig(:airtable, :base_id)

      new(api_key: api_key, base_id: base_id)
    end

    def initialize(api_key: nil, base_id: nil)
      @api_key = api_key || ENV["AIRTABLE_API_KEY"] || Rails.application.credentials.dig(:airtable, :api_key)
      @base_id = base_id || ENV["AIRTABLE_BASE_ID"] || Rails.application.credentials.dig(:airtable, :base_id)

      raise ConfigurationError, "Airtable API key is required" if @api_key.blank?
      raise ConfigurationError, "Airtable base ID is required" if @base_id.blank?
    end

    def list_records(table_name, options = {})
      params = build_list_params(options)
      response = connection.get(table_path(table_name), params)
      handle_response(response)
    end

    def get_record(table_name, record_id)
      response = connection.get(record_path(table_name, record_id))
      handle_response(response)
    end

    def create_record(table_name, fields)
      response = connection.post(table_path(table_name)) do |req|
        req.body = { fields: fields }.to_json
      end
      handle_response(response)
    end

    def update_record(table_name, record_id, fields)
      response = connection.patch(record_path(table_name, record_id)) do |req|
        req.body = { fields: fields }.to_json
      end
      handle_response(response)
    end

    def delete_record(table_name, record_id)
      response = connection.delete(record_path(table_name, record_id))
      handle_response(response)
    end

    def post_sync_csv(table_id_or_name, sync_id, csv_string)
      path = "#{@base_id}/#{ERB::Util.url_encode(table_id_or_name)}/sync/#{ERB::Util.url_encode(sync_id)}"
      response = connection.post(path) do |req|
        req.headers["Content-Type"] = "text/csv"
        req.body = csv_string
      end
      handle_response(response)
    end

    # --- Base schema and batch writes (RecordsSync, for OAuth connections) ---

    def list_tables
      handle_response(connection.get("meta/bases/#{@base_id}/tables"))
    end

    def create_table(name, fields)
      response = connection.post("meta/bases/#{@base_id}/tables") do |req|
        req.body = { name: name, fields: fields }.to_json
      end
      handle_response(response)
    end

    def create_field(table_id, name, type)
      response = connection.post("meta/bases/#{@base_id}/tables/#{ERB::Util.url_encode(table_id)}/fields") do |req|
        req.body = { name: name, type: type }.to_json
      end
      handle_response(response)
    end

    # Up to 10 records per call. Matching on merge_on makes it create-or-update.
    def upsert_records(table_id, fields_list, merge_on:)
      response = connection.patch(table_path(table_id)) do |req|
        req.body = {
          performUpsert: { fieldsToMergeOn: Array(merge_on) },
          records: fields_list.map { |fields| { fields: fields } },
          typecast: true
        }.to_json
      end
      handle_response(response)
    end

    # Up to 10 record ids per call.
    def delete_records(table_id, record_ids)
      handle_response(connection.delete(table_path(table_id), { records: record_ids }))
    end

    private

    # The CSV sync endpoint replaces the whole table snapshot and an upsert
    # PATCH lands on the same records however often it's sent, so replaying
    # either is safe. Other POSTs (create_record) must not be retried: a
    # gateway timeout can mean the record was already created.
    RETRY_SYNC_POST = ->(env, _exception) {
      (env.method == :post && env.url.path.include?("/sync/")) || env.method == :patch
    }

    # A 429 isn't retried here: Airtable refuses the base for 30 seconds, and
    # waiting that out would hold one of the few job threads. It raises
    # RateLimitError so the caller can come back later instead. The cap stops
    # a 5xx Retry-After from holding the job up for the same reason.
    MAX_RETRY_WAIT = 60

    def connection
      @connection ||= Faraday.new(url: BASE_URL) do |conn|
        conn.request :retry, max: 3, interval: 0.5, backoff_factor: 2, max_interval: MAX_RETRY_WAIT,
                     exceptions: [ Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::RetriableResponse ],
                     retry_statuses: [ 500, 502, 503, 504 ],
                     retry_if: RETRY_SYNC_POST
        conn.headers["Authorization"] = "Bearer #{@api_key}"
        conn.headers["Content-Type"] = "application/json"
        conn.options.timeout = 30
        conn.options.open_timeout = 10
      end
    end

    # Paths must be relative: Faraday treats a leading "/" as absolute and
    # drops the /v0 prefix from BASE_URL, which Airtable rejects with
    # 404 INVALID_API_VERSION.
    def table_path(table_name)
      "#{@base_id}/#{ERB::Util.url_encode(table_name)}"
    end

    def record_path(table_name, record_id)
      "#{table_path(table_name)}/#{record_id}"
    end

    def build_list_params(options)
      params = {}
      params[:filterByFormula] = options[:filter] if options[:filter].present?
      params[:sort] = options[:sort] if options[:sort].present?
      params[:fields] = options[:fields] if options[:fields].present?
      params[:maxRecords] = options[:max_records] if options[:max_records].present?
      params[:pageSize] = options[:page_size] if options[:page_size].present?
      params[:offset] = options[:offset] if options[:offset].present?
      params[:view] = options[:view] if options[:view].present?
      params
    end

    def handle_response(response)
      case response.status
      when 200..299
        JSON.parse(response.body)
      when 401
        raise AuthenticationError.new(parse_error_message(response), response: response)
      when 403
        raise ForbiddenError.new(parse_error_message(response), response: response)
      when 404
        raise NotFoundError.new(parse_error_message(response), response: response)
      when 422
        raise ValidationError.new(parse_error_message(response), response: response)
      when 429
        if response.body.to_s.include?("PUBLIC_API_BILLING_LIMIT_EXCEEDED")
          raise QuotaExceededError.new(parse_error_message(response), response: response)
        end
        raise RateLimitError.new(response: response)
      when 500..599
        raise ServerError.new(parse_error_message(response), response: response)
      else
        raise Error.new(parse_error_message(response), response: response)
      end
    end

    # Returns nil when the body carries no detail, so error classes fall back
    # to their default messages.
    def parse_error_message(response)
      parsed = JSON.parse(response.body)
      detail = case (error = parsed["error"])
      when Hash then [ error["type"], error["message"] ].compact.join(": ")
      when String then error
      end
      detail = detail.presence || parsed["message"].presence
      detail && "HTTP #{response.status}: #{detail}"
    rescue JSON::ParserError
      response.body.present? ? "HTTP #{response.status}: #{response.body.truncate(200)}" : nil
    end
  end
end
