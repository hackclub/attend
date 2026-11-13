module RegistrationChangeRequests
  # Compares the guardian details a participant asked for with the guardian
  # already on their registration, and cleans the phone number they typed.
  #
  # Most guardian requests are not replacements at all: they fix a typo in
  # the same parent's email or phone. Telling the two apart lets Approve edit
  # the guardian in place instead of discarding documents they already signed.
  class GuardianDetails
    attr_reader :participant_event, :changes

    def initialize(participant_event, changes)
      @participant_event = participant_event
      @changes = (changes || {}).to_h.stringify_keys
    end

    def current_link
      @current_link ||= participant_event.primary_guardian || participant_event.guardian_participant_events.first
    end

    def current_guardian
      current_link&.guardian
    end

    # The requested phone in E.164, read against the countries this
    # registration most plausibly dials from. Participants routinely type
    # the national form ("0433 764 766"), which the US default rejects.
    def normalized_phone
      return @normalized_phone if defined?(@normalized_phone)

      raw = changes["phone"]
      @normalized_phone = if raw.blank?
        nil
      else
        phone_regions.lazy.map { |region| PhoneNormalizer.normalize(raw, default_country: region) }.find(&:present?)
      end
    end

    def phone_unreadable?
      changes["phone"].present? && normalized_phone.nil?
    end

    # The requested changes with the phone rewritten to E.164 when it parses.
    def normalized_changes
      return changes unless normalized_phone

      changes.merge("phone" => normalized_phone)
    end

    # The same person as the current guardian, with a typo fixed somewhere.
    #
    # A matching name is enough, unless both the email and the phone change.
    # A matching email or phone on its own is not:
    # households share both, and "replace mum with my older sibling, same
    # email" is a real replacement whose new guardian has to sign. So a
    # different name only counts as the same person when it is a near-miss
    # spelling and another detail matches, or when both email and phone do.
    def same_person?
      return false unless current_guardian
      # A matching name with a new email AND a new phone is someone else with
      # the same name as far as we can tell, so it goes through replacement.
      return !(email_changes? && phone_changes?) if same_name?
      return true if same_email? && same_phone?

      near_name? && (same_email? || same_phone?)
    end

    # Nothing would change: every detail already matches the guardian on file.
    def identical?
      return false unless current_guardian

      same_email? && same_name? && (changes["phone"].blank? || same_phone?) &&
        (changes["relationship"].blank? || squish(changes["relationship"]) == squish(current_link.relationship))
    end

    def same_email?
      email = changes["email"].to_s.strip.downcase
      email.present? && email == current_guardian.email.to_s.strip.downcase
    end

    def same_name?
      requested = name_key(changes["legal_first_name"], changes["legal_last_name"])
      requested.present? && requested == name_key(current_guardian.legal_first_name, current_guardian.legal_last_name)
    end

    def same_phone?
      return false if current_guardian.phone.blank? || changes["phone"].blank?

      if normalized_phone
        normalized_phone == current_guardian.phone
      else
        # Unparseable input: fall back to comparing the subscriber digits.
        last_digits(changes["phone"]) == last_digits(current_guardian.phone)
      end
    end

    private

    NEAR_NAME_DISTANCE = 2

    def email_changes?
      changes["email"].present? && !same_email?
    end

    def phone_changes?
      changes["phone"].present? && !same_phone?
    end

    def near_name?
      requested = name_key(changes["legal_first_name"], changes["legal_last_name"])
      current = name_key(current_guardian.legal_first_name, current_guardian.legal_last_name)
      return false if requested.blank? || current.blank?

      DidYouMean::Levenshtein.distance(requested, current) <= NEAR_NAME_DISTANCE
    end

    def phone_regions
      [
        PhoneNormalizer.country(current_guardian&.phone),
        PhoneNormalizer.country(participant_event.participant.phone),
        country_code(participant_event.participant.try(:country_of_residence)),
        PhoneNormalizer::DEFAULT_COUNTRY
      ].compact.uniq
    end

    def country_code(value)
      value.to_s.strip.upcase.presence if value.to_s.strip.match?(/\A[a-zA-Z]{2}\z/)
    end

    def name_key(first, last)
      I18n.transliterate("#{first}#{last}").downcase.gsub(/[^a-z]/, "")
    end

    def squish(value)
      value.to_s.squish.downcase
    end

    def last_digits(value)
      value.to_s.gsub(/\D/, "").last(9)
    end
  end
end
