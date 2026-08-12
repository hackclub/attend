module Docuseal
  # Clones a blueprint waiver template on DocuSeal for an event and
  # auto-applies the default field mappings, so organizers never have to
  # visit the mappings screen for the standard waivers.
  class DefaultTemplateSetup
    BLUEPRINT_IDS = {
      "waiver" => 1,
      "freedom_waiver" => 2
    }.freeze

    # Field names match the blueprint templates verbatim, so we can wire them
    # up without making the user visit the mappings screen.
    DEFAULT_MAPPINGS = {
      "waiver" => [
        { "field_name" => "Full Name", "source_key" => "participant.full_name", "readonly" => true, "role" => "Attendee" },
        { "field_name" => "Phone Number", "source_key" => "participant.phone", "readonly" => true, "role" => "Attendee" },
        { "field_name" => "Emergency Contact - Full Name", "source_key" => "emergency_contact.name", "readonly" => true, "role" => "Attendee" },
        { "field_name" => "Emergency Contact - Relationship to Attendee", "source_key" => "emergency_contact.relationship", "readonly" => true, "role" => "Attendee" },
        { "field_name" => "Emergency Contact - Phone Number", "source_key" => "emergency_contact.phone", "readonly" => true, "role" => "Attendee" },
        { "field_name" => "Full Name", "source_key" => "guardian.full_name", "readonly" => true, "role" => "Parent/Legal Guardian" },
        { "field_name" => "Phone Number", "source_key" => "guardian.phone", "readonly" => true, "role" => "Parent/Legal Guardian" }
      ],
      "freedom_waiver" => [
        { "field_name" => "Attendee - Full Name", "source_key" => "participant.full_name", "readonly" => true, "role" => "Parent/Guardian" },
        { "field_name" => "Attendee - Phone Number", "source_key" => "participant.phone", "readonly" => true, "role" => "Parent/Guardian" },
        { "field_name" => "Date of Birth", "source_key" => "participant.date_of_birth", "readonly" => true, "role" => "Parent/Guardian" },
        { "field_name" => "Full Name", "source_key" => "guardian.full_name", "readonly" => true, "role" => "Parent/Guardian" }
      ]
    }.freeze

    DEFAULT_FREEDOM_CHECKBOX_CONFIG = {
      "granted_field" => "Freedom Waiver Granted",
      "rejected_field" => "Freedom Waiver Rejected"
    }.freeze

    TEMPLATE_COLUMNS = {
      "waiver" => :docuseal_waiver_template_id,
      "freedom_waiver" => :docuseal_freedom_waiver_template_id,
      "adult_waiver" => :docuseal_adult_waiver_template_id
    }.freeze

    class Result
      attr_reader :message

      def initialize(success, message)
        @success = success
        @message = message
      end

      def success?
        @success
      end
    end

    def initialize(event)
      @event = event
    end

    def call(template_type)
      blueprint_id = BLUEPRINT_IDS[template_type]
      if blueprint_id.nil?
        return Result.new(false, "No default template available for #{template_type.humanize}.")
      end

      label = template_type.titleize
      # If this event already has another DocuSeal template configured, stay on
      # that host so we don't split an event across two hosts. Otherwise this
      # is the first template — provision it on the current default cluster.
      target_host = if event_has_any_template?
        @event.docuseal_host
      else
        Docuseal::HostConfig.default_host
      end

      clone = Docuseal::Client.new(host: target_host).clone_template(
        blueprint_id,
        name: "#{@event.name} - #{label}",
        folder_name: @event.name,
        external_id: "attend_event_#{@event.id}_#{template_type}",
        values: {
          event_name: @event.name,
          event_dates: @event.formatted_date_range.to_s
        }
      )

      @event.update!(
        TEMPLATE_COLUMNS.fetch(template_type) => clone["id"],
        docuseal_host: target_host
      )
      config_update = {
        "template_snapshot" => nil,
        "mappings" => DEFAULT_MAPPINGS[template_type] || []
      }
      if template_type == "freedom_waiver"
        config_update["freedom_checkbox_config"] = DEFAULT_FREEDOM_CHECKBOX_CONFIG
      end
      update_template_config(template_type, config_update)

      Result.new(true, "Default #{label} template created and field mappings configured.")
    rescue Docuseal::Error => e
      Result.new(false, "Failed to use default template: #{e.message}")
    end

    private

    def event_has_any_template?
      @event.docuseal_waiver_template_id.present? ||
        @event.docuseal_freedom_waiver_template_id.present? ||
        @event.docuseal_adult_waiver_template_id.present?
    end

    def update_template_config(template_type, updates)
      mappings = @event.docuseal_field_mappings || {}
      mappings[template_type] ||= {}
      mappings[template_type].merge!(updates)
      @event.update!(docuseal_field_mappings: mappings)
    end
  end
end
