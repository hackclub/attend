module Docuseal
  class FieldMapper
    DATA_SOURCES = {
      "participant.full_name" => ->(ctx) { ctx[:participant]&.full_name },
      "participant.legal_first_name" => ->(ctx) { ctx[:participant]&.legal_first_name },
      "participant.legal_last_name" => ->(ctx) { ctx[:participant]&.legal_last_name },
      "participant.preferred_name" => ->(ctx) { ctx[:participant]&.preferred_name },
      "participant.email" => ->(ctx) { ctx[:participant]&.email },
      "participant.phone" => ->(ctx) { ctx[:participant]&.phone },
      "participant.date_of_birth" => ->(ctx) { ctx[:participant]&.date_of_birth&.strftime("%Y-%m-%d") },
      "guardian.full_name" => ->(ctx) { ctx[:guardian]&.full_name },
      "guardian.email" => ->(ctx) { ctx[:guardian]&.email },
      "guardian.phone" => ->(ctx) { ctx[:guardian]&.phone },
      "emergency_contact.name" => ->(ctx) { ctx[:emergency_contacts]&.first&.name },
      "emergency_contact.phone" => ->(ctx) { ctx[:emergency_contacts]&.first&.phone },
      "emergency_contact.relationship" => ->(ctx) { ctx[:emergency_contacts]&.first&.relationship },
      "event.name" => ->(ctx) { ctx[:event]&.name },
      "event.venue_name" => ->(ctx) { ctx[:event]&.venue_name },
      "event.location_address" => ->(ctx) { ctx[:event]&.location_address }
    }.freeze

    attr_reader :event, :template_type, :mappings

    def initialize(event:, template_type:)
      @event = event
      @template_type = template_type.to_s
      @config = event.docuseal_field_mappings&.dig(@template_type) || {}
      @mappings = @config["mappings"] || []
    end

    def has_mappings?
      @mappings.present?
    end

    def build_fields_for_role(role:, context:)
      return [] unless has_mappings?

      # Match mappings where the role is blank, or where the role name matches
      # Also treat "Attendee" and "Participant" as equivalent for backwards compatibility
      role_mappings = @mappings.select do |m|
        next true if m["role"].blank?
        mapping_role = m["role"]&.downcase
        search_role = role.downcase
        mapping_role&.include?(search_role) ||
          (search_role.include?("attendee") && mapping_role == "participant") ||
          (search_role.include?("participant") && mapping_role == "attendee")
      end

      role_mappings.filter_map do |mapping|
        value = resolve_value(mapping["source_key"], context)
        next if value.blank?

        {
          name: mapping["field_name"],
          default_value: value,
          readonly: mapping["readonly"] == true
        }
      end
    end

    def resolve_value(source_key, context)
      return nil if source_key.blank?

      resolver = DATA_SOURCES[source_key]
      return nil unless resolver

      resolver.call(context)
    end

    def freedom_checkbox_config
      @config["freedom_checkbox_config"] || {}
    end

    def self.data_sources_for_display
      {
        "participant.full_name" => "Participant Full Name",
        "participant.legal_first_name" => "Participant Legal First Name",
        "participant.legal_last_name" => "Participant Legal Last Name",
        "participant.preferred_name" => "Participant Preferred Name",
        "participant.email" => "Participant Email",
        "participant.phone" => "Participant Phone",
        "participant.date_of_birth" => "Participant Date of Birth",
        "guardian.full_name" => "Guardian Full Name",
        "guardian.email" => "Guardian Email",
        "guardian.phone" => "Guardian Phone",
        "emergency_contact.name" => "Emergency Contact Name",
        "emergency_contact.phone" => "Emergency Contact Phone",
        "emergency_contact.relationship" => "Emergency Contact Relationship",
        "event.name" => "Event Name",
        "event.venue_name" => "Event Venue",
        "event.location_address" => "Event Address"
      }
    end
  end
end
