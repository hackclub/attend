module DocusealHelper
  # Generate JWT token for DocuSeal embedded builder
  # @param template_id [String, nil] existing template ID (for editing)
  # @param document_urls [Array<String>, nil] URLs of documents to create template from
  # @param name [String] template name
  def docuseal_builder_token(template_id: nil, document_urls: nil, name: "New Template", folder_name: nil, host: nil)
    settings = Docuseal::HostConfig.for_host(host)
    api_key = settings[:api_key]
    raise ArgumentError, "DocuSeal API key is required for host #{settings[:host]}" if api_key.blank?

    payload = {
      user_email: "leo@hackclub.com",
      integration_email: "leo@hackclub.com",
      name: name
    }
    payload[:folder_name] = folder_name if folder_name.present?

    if template_id.present?
      payload[:template_id] = template_id.to_i
    else
      # Pass empty array to allow users to upload their files
      payload[:document_urls] = document_urls.present? ? Array(document_urls) : []
    end

    JWT.encode(payload, api_key, "HS256")
  end

  # Available data sources for field mapping
  # Returns hash of source_key => display label
  def docuseal_data_sources
    Docuseal::FieldMapper.data_sources_for_display
  end
end
