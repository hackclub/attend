module Admin
  module MessagesHelper
    # What the message form says about SMS for this event: whether the event
    # itself is somewhere we can't text, and how many of its people have
    # numbers in countries we can't text (see SmsRoute).
    SmsCoverage = Struct.new(:event_country, :people_by_country, :whatsapp, keyword_init: true) do
      # With WhatsApp on, the SMS channel still reaches people there by
      # WhatsApp, so it stays usable; without it there's nothing to send.
      def channel_disabled?
        event_country.present? && !whatsapp
      end

      def event_country_name
        SmsRoute.country_name(event_country) if event_country
      end

      def any_people?
        people_by_country.any?
      end
    end

    def sms_coverage(event)
      @sms_coverage ||= begin
        phones = event.participants.merge(ParticipantEvent.active).pluck(:phone) +
          Guardian.joins(guardian_participant_events: :participant_event)
                  .merge(ParticipantEvent.active.where(event_id: event.id)).distinct.pluck(:phone)
        people = phones.compact_blank.uniq.filter_map { |phone| SmsRoute.no_sms_country_for(phone) }.tally
        SmsCoverage.new(
          event_country: SmsRoute.no_sms_country_named(event.location_country),
          people_by_country: people.sort_by { |code, count| [ -count, code ] }.to_h,
          whatsapp: Setting.whatsapp_enabled?
        )
      end
    end

    # "Uzbekistan (40), Mongolia (2) and other countries (3)"
    def sms_coverage_countries(coverage)
      named, others = coverage.people_by_country.partition { |code, _| SmsRoute::NO_SMS_COUNTRIES.key?(code) }
      parts = named.map { |code, count| "#{SmsRoute.country_name(code)} (#{count})" }
      parts << "other countries (#{others.sum { |_, count| count }})" if others.any?
      parts.to_sentence
    end

    # The sentence under the SMS channel when some of the event's people
    # can't be texted.
    def sms_coverage_notice(coverage)
      people = coverage.people_by_country.values.sum
      reach = coverage.whatsapp ? "They'll get WhatsApp instead if they use it." : "They won't get this by text."
      "SMS isn't available in some countries. #{pluralize(people, 'person')} in this event #{people == 1 ? 'has a number' : 'have numbers'} there: #{sms_coverage_countries(coverage)}. #{reach}"
    end

    def sms_event_country_notice(coverage)
      if coverage.channel_disabled?
        "SMS isn't available in #{coverage.event_country_name}."
      else
        "SMS isn't available in #{coverage.event_country_name}. People with numbers there get WhatsApp only."
      end
    end

    def sms_channel_label(label)
      Setting.whatsapp_enabled? ? "SMS / WhatsApp" : label
    end
  end
end
