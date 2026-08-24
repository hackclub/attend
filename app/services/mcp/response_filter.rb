module Mcp
  # Strips identifying detail out of an MCP tool response before it leaves the
  # server, for connections the user marked as anonymized.
  #
  # Two passes over the payload hash:
  #
  #   * keys that always hold a person's name become initials ("Leo Wilkin" → "L.W.")
  #   * keys that always hold contact or location detail become "[redacted]"
  #   * every remaining string is scrubbed for inline emails and phone numbers,
  #     because free text (notes, ticket bodies, incident details) is where
  #     contact details actually end up
  #
  # `name` is deliberately not in either list: it means a room, group, or event
  # as often as it means a person. Toolboxes run person names through
  # ApplicationToolbox#participant_name / #person_name instead, which is why
  # #initials is idempotent — a value may pass through both.
  module ResponseFilter
    REDACTED = "[redacted]".freeze

    NAME_KEYS = %w[
      legal_name full_name preferred_name display_name participant_name
      guardian_name author sent_by reported_by last_updated_by assigned_to
      closed_by created_by from staff_names roommate_name occupant_name
      emergency_contact_name next_of_kin
    ].to_set.freeze

    REDACTED_KEYS = %w[
      email emails email_address personal_email work_email guardian_email
      phone phone_number phone_numbers mobile mobile_number home_phone
      twilio_to_number from_number to_number guardian_phone
      emergency_contact_phone emergency_contact emergency_contacts
      slack_user_id slack_id discord_id
      date_of_birth dob
      address street_address address_line1 address_line2 mailing_address
      postal_code postcode zip zipcode city state
      passport_number national_id ip_address
    ].to_set.freeze

    EMAIL_PATTERN = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i
    # Seven or more digits with optional separators, not glued to a word (so
    # flight codes like AA1234 and ids survive). Deliberately loose: a false
    # positive costs a redacted number in free text, a miss leaks one.
    PHONE_PATTERN = /(?<![\w.])\+?\d[\d\s().-]{5,}\d(?![\w.])/
    INITIALS_PATTERN = /\A(?:\p{Lu}\.)+\z/

    class << self
      def call(payload)
        filter(payload)
      end

      # "Leo Wilkin" → "L.W.", "Leo" → "L.", "L.W." → "L.W."
      def initials(value)
        return value if value.nil?

        text = value.to_s.strip
        return value if text.empty?
        return text if text.match?(INITIALS_PATTERN)

        letters = text.split(/[\s\-_.]+/).filter_map { |part| part[/\p{L}/] }
        return REDACTED if letters.empty?

        letters.map { |letter| "#{letter.upcase}." }.join
      end

      private

      def filter(value, key = nil)
        case value
        when Hash
          value.to_h { |k, v| [ k, filter(v, k) ] }
        when Array
          value.map { |v| filter(v, key) }
        when String
          filter_string(value, key)
        else
          # Times, numbers, booleans and nils carry no names or contact details.
          redacted_key?(key) && !value.nil? ? REDACTED : value
        end
      end

      def filter_string(value, key)
        return REDACTED if redacted_key?(key)
        return initials(value) if name_key?(key)

        scrub(value)
      end

      def scrub(text)
        text.gsub(EMAIL_PATTERN, REDACTED).gsub(PHONE_PATTERN, REDACTED)
      end

      def name_key?(key) = key.present? && NAME_KEYS.include?(key.to_s)

      def redacted_key?(key) = key.present? && REDACTED_KEYS.include?(key.to_s)
    end
  end
end
