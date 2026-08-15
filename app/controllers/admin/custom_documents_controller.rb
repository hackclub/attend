module Admin
  class CustomDocumentsController < BaseController
    before_action :set_event

    def create
      custom_document = @event.custom_documents.build(custom_document_params)

      if custom_document.save
        notice = if custom_document.optional?
          "\"#{custom_document.name}\" added as optional. Nobody is asked to sign it until a participant adds it themselves."
        elsif custom_document.physical?
          "\"#{custom_document.name}\" added. Participants will download it, sign it physically, and upload a photo."
        else
          "\"#{custom_document.name}\" added. Sync its fields to configure pre-fill mappings."
        end
        redirect_to admin_event_integrations_path(@event), notice: notice
      else
        redirect_to admin_event_integrations_path(@event),
                    alert: "Couldn't add document: #{custom_document.errors.full_messages.to_sentence}"
      end
    rescue ArgumentError => e
      # Enum setters (document_kind, signer_type) raise on values outside the
      # allowed set rather than adding a validation error.
      redirect_to admin_event_integrations_path(@event), alert: "Couldn't add document: #{e.message}"
    end

    def destroy
      custom_document = @event.custom_documents.find(params[:id])

      if custom_document.consents.exists?
        # Signed/sent documents are legal records — keep the row so consents
        # stay labelled, just hide it from participants and the add flow.
        custom_document.archive!
        remove_field_mappings(custom_document)
        redirect_to admin_event_integrations_path(@event),
                    notice: "\"#{custom_document.name}\" archived. Existing signatures are kept."
      else
        custom_document.destroy!
        remove_field_mappings(custom_document)
        redirect_to admin_event_integrations_path(@event),
                    notice: "\"#{custom_document.name}\" removed."
      end
    end

    private

    def set_event
      @event = Event.find_by!(slug: params[:slug])
      authorize @event, :update?
      set_current_event(@event)
    end

    def custom_document_params
      params.require(:custom_document)
            .permit(:name, :document_kind, :description, :docuseal_template_id, :signer_type, :template_pdf, :optional)
    end

    def remove_field_mappings(custom_document)
      mappings = @event.docuseal_field_mappings || {}
      return unless mappings.key?(custom_document.mapping_key)

      mappings.delete(custom_document.mapping_key)
      @event.update!(docuseal_field_mappings: mappings)
    end
  end
end
