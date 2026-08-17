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

    def edit
      @custom_document = @event.custom_documents.find(params[:id])
    end

    def update
      @custom_document = @event.custom_documents.find(params[:id])
      attributes = editable_params(@custom_document)

      # Switching an electronic document to paper leaves its template id behind
      # as a stale pointer, so drop it as part of the same save.
      switching_to_physical = attributes[:document_kind] == "physical" && @custom_document.electronic?
      attributes[:docuseal_template_id] = nil if switching_to_physical

      switching_to_electronic = attributes[:document_kind] == "electronic" && @custom_document.physical?
      template_id_changed = attributes.key?(:docuseal_template_id) &&
        attributes[:docuseal_template_id] != @custom_document.docuseal_template_id

      if @custom_document.update(attributes)
        # Mappings are keyed by the old template's field names, so they're
        # meaningless once the template changes or the document goes physical.
        remove_field_mappings(@custom_document) if template_id_changed

        if switching_to_electronic
          @custom_document.template_pdf.purge_later
          @custom_document.update_column(:template_page_count, nil)
        end

        redirect_to admin_event_integrations_path(@event),
                    notice: "\"#{@custom_document.name}\" updated.#{" Sync its fields again to reconfigure pre-fill." if template_id_changed && @custom_document.electronic?}"
      else
        flash.now[:alert] = "Couldn't update document: #{@custom_document.errors.full_messages.to_sentence}"
        render :edit, status: :unprocessable_entity
      end
    rescue ArgumentError => e
      redirect_to admin_event_custom_document_edit_path(@event, @custom_document),
                  alert: "Couldn't update document: #{e.message}"
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

    # Name and description are labels — safe to change at any point, and the
    # new wording shows up on every existing consent. Everything else changes
    # who must sign or how, and DocuSeal submissions have already been created
    # against the old shape, so it's frozen once anybody has a consent.
    def editable_params(custom_document)
      permitted = [ :name, :description ]
      if custom_document.consents.none?
        permitted += [ :document_kind, :docuseal_template_id, :signer_type, :template_pdf, :optional ]
      end

      params.require(:custom_document).permit(*permitted)
    end

    def remove_field_mappings(custom_document)
      mappings = @event.docuseal_field_mappings || {}
      return unless mappings.key?(custom_document.mapping_key)

      mappings.delete(custom_document.mapping_key)
      @event.update!(docuseal_field_mappings: mappings)
    end
  end
end
