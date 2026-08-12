module Docuseal
  class Client
    attr_reader :host

    # Build a client bound to the host stored on a record (event/consent).
    # All API calls for that record will hit the matching cluster.
    def self.for(record)
      host = record.respond_to?(:docuseal_host) ? record.docuseal_host : nil
      new(host: host)
    end

    def initialize(host: nil, api_key: nil, base_url: nil)
      settings = Docuseal::HostConfig.for_host(host)
      @host = settings[:host]
      @api_key = api_key || settings[:api_key]
      @base_url = base_url || settings[:api_base_url]

      raise ArgumentError, "Docuseal API key is required for host #{@host}" if @api_key.blank?
    end

    def create_submission(template_id:, submitters:, metadata: {}, send_email: true, order: "preserved", completed_redirect_url: nil)
      payload = {
        template_id: template_id,
        submitters: submitters.map { |s| format_submitter(s) },
        metadata: metadata,
        send_email: send_email,
        order: order
      }
      payload[:completed_redirect_url] = completed_redirect_url if completed_redirect_url.present?

      response = connection.post("submissions", payload)
      handle_response(response)
    end

    def get_submission(submission_id)
      response = connection.get("submissions/#{submission_id}")
      handle_response(response)
    end

    def get_submission_documents(submission_id)
      response = connection.get("submissions/#{submission_id}/documents")
      handle_response(response)
    end

    def get_template(template_id)
      response = connection.get("templates/#{template_id}")
      handle_response(response)
    end

    def clone_template(template_id, name: nil, folder_name: nil, external_id: nil, values: nil)
      payload = {}
      payload[:name] = name if name.present?
      payload[:folder_name] = folder_name if folder_name.present?
      payload[:external_id] = external_id if external_id.present?
      payload[:values] = values if values.present?

      response = connection.post("templates/#{template_id}/clone", payload)
      handle_response(response)
    end

    def archive_submission(submission_id)
      response = connection.delete("submissions/#{submission_id}")
      handle_response(response)
    end

    private

    def connection
      @connection ||= Faraday.new(url: @base_url) do |conn|
        conn.request :json
        conn.response :json, content_type: /\bjson$/
        conn.headers["X-Auth-Token"] = @api_key
        conn.headers["Content-Type"] = "application/json"
        conn.adapter Faraday.default_adapter
      end
    end

    def format_submitter(submitter)
      result = {
        email: submitter[:email],
        name: submitter[:name],
        role: submitter[:role]
      }
      result[:fields] = submitter[:fields] if submitter[:fields].present?
      result[:send_email] = submitter[:send_email] if submitter.key?(:send_email)
      result.compact
    end

    def handle_response(response)
      case response.status
      when 200..299
        response.body
      when 401
        raise Docuseal::AuthenticationError.new("Invalid API key", response: response, status: response.status)
      when 404
        raise Docuseal::NotFoundError.new("Resource not found", response: response, status: response.status)
      when 422
        raise Docuseal::ValidationError.new(extract_error_message(response), response: response, status: response.status)
      when 429
        raise Docuseal::RateLimitError.new("Rate limit exceeded", response: response, status: response.status)
      else
        raise Docuseal::Error.new(extract_error_message(response), response: response, status: response.status)
      end
    end

    def extract_error_message(response)
      return response.body["error"] if response.body.is_a?(Hash) && response.body["error"]
      return response.body["message"] if response.body.is_a?(Hash) && response.body["message"]

      "Docuseal API error (status: #{response.status})"
    end
  end
end
