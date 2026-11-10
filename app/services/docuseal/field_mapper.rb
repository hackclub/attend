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
      @mappings = with_field_uuids(@config["mappings"] || [])
    end

    def has_mappings?
      @mappings.present?
    end

    # template: the live DocuSeal template, when the caller has it. A mapping
    # pinned to a field uuid the template no longer has (it was edited after
    # the last sync) falls back to the field's name rather than going missing.
    def build_fields_for_role(role:, context:, template: nil)
      return [] unless has_mappings?

      live_uuids = template && Array(template["fields"]).map { |f| f["uuid"] }.to_set

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

      fields = role_mappings.filter_map do |mapping|
        value = resolve_value(mapping["source_key"], context)
        next if value.blank?

        uuid = mapping["field_uuid"].presence
        uuid = nil if uuid && live_uuids && !live_uuids.include?(uuid)
        # DocuSeal matches by name first and ignores uuid when a name is sent,
        # so a uuid-pinned field must go without its name.
        target = uuid ? { uuid: uuid } : { name: mapping["field_name"] }
        target.merge(default_value: value, readonly: mapping["readonly"] == true)
      end

      # DocuSeal fills every field sharing a name with the first matching
      # entry, so a second entry for the same name can only conflict with it.
      fields.uniq { |field| field[:uuid] || field[:name].to_s.downcase }
    end

    # The mapping saved for one row of the mappings page. Rows are template
    # fields, and a template can repeat a name within a role (two "Full Name"
    # boxes), so match the field's uuid rather than its name.
    def mapping_for_field(field)
      @mappings.find { |m| m["field_uuid"].present? && m["field_uuid"] == field["uuid"] } ||
        @mappings.find do |m|
          m["field_uuid"].blank? && m["field_name"] == field["name"] &&
            m["role"].presence == role_name_for(field)
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

    private

    def snapshot_fields
      Array(@config.dig("template_snapshot", "fields")).reject { |f| f["readonly"] }
    end

    def role_name_for(field)
      @role_names ||= Array(@config.dig("template_snapshot", "submitters")).to_h { |s| [ s["uuid"], s["name"] ] }
      @role_names[field["submitter_uuid"]].presence
    end

    # Mappings saved before field uuids were recorded carry only a name and
    # role. Where a template repeats a name within a role, those collide:
    # DocuSeal gives every same-named field one value. The mappings page saved
    # rows in template order and only mapped rows, so when a role has as many
    # legacy mappings for a name as the template has fields, they pair up by
    # position. Anything less is ambiguous and stays name-only.
    def with_field_uuids(mappings)
      legacy = mappings.select { |m| m["field_uuid"].blank? }
      return mappings if legacy.empty?

      fields_by_key = snapshot_fields.group_by { |f| [ f["name"], role_name_for(f) ] }
      legacy_by_key = legacy.group_by { |m| [ m["field_name"], m["role"].presence ] }

      uuid_for = {}
      legacy_by_key.each do |key, group|
        fields = fields_by_key[key]
        next unless fields && fields.size == group.size

        group.zip(fields) { |mapping, field| uuid_for[mapping.object_id] = field["uuid"] }
      end

      mappings.map do |m|
        uuid = uuid_for[m.object_id]
        uuid.present? ? m.merge("field_uuid" => uuid) : m
      end
    end
  end
end
