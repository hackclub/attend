module Airtable
  # Redacts Airtable personal access tokens from the places events.config was
  # copied to: PaperTrail versions (YAML text) and audit logs (jsonb). Used by
  # `rails airtable:scrub_leaked_tokens`.
  module TokenScrubber
    REDACTED = "[REDACTED]".freeze
    # config is jsonb, so versions hold it as a JSON string inside the YAML...
    JSON_PAIR = /"airtable_api_key"\s*:\s*"(?:[^"\\]|\\.)+"/
    # ...unless it was ever serialised as a YAML mapping.
    YAML_PAIR = /^(\s*(?:-\s+)?)airtable_api_key:[ \t]*(?!(?:''|""|null|~)?$)\S.*$/

    module_function

    def scrub_text(text)
      return text if text.blank?

      text.gsub(JSON_PAIR, %("airtable_api_key":"#{REDACTED}"))
          .gsub(YAML_PAIR) { "#{$1}airtable_api_key: \"#{REDACTED}\"" }
    end

    def scrub_value(value)
      case value
      when Hash
        value.to_h do |key, inner|
          if key.to_s == "airtable_api_key" && inner.is_a?(String) && inner.present?
            [ key, REDACTED ]
          else
            [ key, scrub_value(inner) ]
          end
        end
      when Array then value.map { |inner| scrub_value(inner) }
      when String then scrub_text(value)
      else value
      end
    end
  end
end
