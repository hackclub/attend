module Admin
  class DocusealTemplatesController < BaseController
    include DocusealHelper

    before_action :set_event
    before_action :set_template_type

    VALID_TEMPLATE_TYPES = %w[waiver freedom_waiver adult_waiver].freeze

    def use_default
      if custom_template_type?
        redirect_to admin_event_integrations_path(@event), alert: "Custom documents don't have a default template."
        return
      end

      result = Docuseal::DefaultTemplateSetup.new(@event).call(@template_type)

      if result.success?
        redirect_to admin_event_integrations_path(@event), notice: result.message
      else
        redirect_to admin_event_integrations_path(@event), alert: result.message
      end
    end

    def sync
      template_id = template_id_for_type

      if template_id.blank?
        redirect_to admin_event_integrations_path(@event),
                    alert: "No template configured. Please create one first."
        return
      end

      begin
        client = Docuseal::Client.for(@event)
        template = client.get_template(template_id)

        update_template_config({
          "template_snapshot" => {
            "synced_at" => Time.current.iso8601,
            "submitters" => template["submitters"],
            "fields" => template["fields"]
          }
        })

        redirect_to admin_event_docuseal_template_mappings_path(@event, @template_type),
                    notice: "Template fields synced successfully."
      rescue Docuseal::Error => e
        redirect_to admin_event_docuseal_template_mappings_path(@event, @template_type),
                    alert: "Failed to sync template: #{e.message}"
      end
    end

    def mappings
      @display_name = @custom_document&.name || @template_type.titleize
      @template_id = template_id_for_type
      @template_config = current_template_config
      @template_snapshot = @template_config["template_snapshot"]
      @current_mappings = @template_config["mappings"] || []
      @freedom_checkbox_config = @template_config["freedom_checkbox_config"] || {}
      @data_sources = docuseal_data_sources
    end

    def update_mappings
      mappings = params[:mappings] || []

      parsed_mappings = mappings.map do |m|
        next if m[:source_key].blank?
        {
          "field_name" => m[:field_name],
          "source_key" => m[:source_key],
          "readonly" => m[:readonly] == "1" || m[:readonly] == true,
          "role" => m[:role]
        }
      end.compact

      config_update = { "mappings" => parsed_mappings }

      if @template_type == "freedom_waiver"
        config_update["freedom_checkbox_config"] = {
          "granted_field" => params[:freedom_granted_field],
          "rejected_field" => params[:freedom_rejected_field]
        }
      end

      update_template_config(config_update)

      redirect_to admin_event_docuseal_template_mappings_path(@event, @template_type),
                  notice: "Field mappings saved successfully."
    end

    private

    def set_event
      @event = Event.find_by!(slug: params[:slug])
      authorize @event, :update?
      set_current_event(@event)
    end

    def set_template_type
      @template_type = params[:template_type]

      if @template_type&.start_with?("custom_")
        @custom_document = @event.custom_documents.find_by(id: @template_type.delete_prefix("custom_"))
        redirect_to admin_event_integrations_path(@event), alert: "Custom document not found" if @custom_document.nil?
      elsif !VALID_TEMPLATE_TYPES.include?(@template_type)
        redirect_to admin_event_integrations_path(@event), alert: "Invalid template type"
      end
    end

    def custom_template_type?
      @custom_document.present?
    end

    def template_id_for_type
      case @template_type
      when "waiver"
        @event.docuseal_waiver_template_id
      when "freedom_waiver"
        @event.docuseal_freedom_waiver_template_id
      when "adult_waiver"
        @event.docuseal_adult_waiver_template_id
      else
        @custom_document&.docuseal_template_id
      end
    end

    def current_template_config
      mappings = @event.docuseal_field_mappings || {}
      mappings[@template_type] || {}
    end

    def update_template_config(updates)
      mappings = @event.docuseal_field_mappings || {}
      mappings[@template_type] ||= {}
      mappings[@template_type].merge!(updates)
      @event.update!(docuseal_field_mappings: mappings)
    end
  end
end
