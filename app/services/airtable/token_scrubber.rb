module Airtable
  # Redacts Airtable personal access tokens from the places events.config was
  # copied to: PaperTrail versions (serialised YAML) and audit logs (jsonb).
  # Used by `rails airtable:scrub_leaked_tokens`.
  #
  # Works on parsed structures rather than pattern-matching serialised text,
  # so quoting, escaping or line folding can't hide a token from it.
  module TokenScrubber
    KEY = "airtable_api_key".freeze
    REDACTED = "[REDACTED]".freeze

    module_function

    # A version's object/object_changes, through PaperTrail's own serializer.
    # Raises if the text can't be parsed: an unreadable row must be looked at,
    # not silently passed over as clean.
    def scrub_serialized(text)
      return text if text.blank?

      loaded = PaperTrail.serializer.load(text)
      scrubbed = scrub_value(loaded)
      scrubbed == loaded ? text : PaperTrail.serializer.dump(scrubbed)
    end

    def scrub_value(value)
      case value
      when Hash
        value.to_h do |key, inner|
          key.to_s == KEY && live_token?(inner) ? [ key, REDACTED ] : [ key, scrub_value(inner) ]
        end
      when Array then value.map { |inner| scrub_value(inner) }
      # jsonb columns reach PaperTrail as JSON strings.
      when String then scrub_json_string(value)
      else value
      end
    end

    # True when a parsed structure still holds a token anywhere.
    def leaks?(value)
      case value
      when Hash then value.any? { |key, inner| (key.to_s == KEY && live_token?(inner)) || leaks?(inner) }
      when Array then value.any? { |inner| leaks?(inner) }
      when String then value.include?(KEY) && !!(parsed = parse_json(value)) && leaks?(parsed)
      else false
      end
    end

    def serialized_leaks?(text)
      text.present? && leaks?(PaperTrail.serializer.load(text))
    end

    def live_token?(value)
      value.is_a?(String) && value.strip.present? && value != REDACTED
    end

    def scrub_json_string(value)
      return value unless value.include?(KEY)

      parsed = parse_json(value)
      return value unless parsed

      scrubbed = scrub_value(parsed)
      scrubbed == parsed ? value : scrubbed.to_json
    end

    def parse_json(value)
      parsed = JSON.parse(value)
      parsed if parsed.is_a?(Hash) || parsed.is_a?(Array)
    rescue JSON::ParserError
      nil
    end
  end
end
