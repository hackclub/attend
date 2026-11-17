module Admin
  class GuardiansController < BaseController
    before_action :require_event_selected
    before_action :set_participant_event
    before_action :set_guardian_participant_event
    # The form is nothing but a guardian's contact details and address, none of
    # which PII-restricted roles may see, so they can't open or submit it.
    before_action :require_contact_details_access

    def edit
      @guardian = @guardian_participant_event.guardian
    end

    def update
      @guardian = @guardian_participant_event.guardian

      result = Guardians::Update.call(operation_context,
        participant_event: @participant_event,
        guardian_participant_event: @guardian_participant_event,
        attributes: guardian_params)

      if result.success?
        redirect_to admin_event_participant_path(current_event, @participant_event),
          notice: "Guardian information updated successfully."
      elsif result.code == :pii_restricted
        require_contact_details_access
      else
        # @guardian carries the errors: a failed validation, or a phone number
        # that is also the participant's.
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def require_contact_details_access
      return if can_view_participant_pii?

      redirect_to admin_event_participant_path(current_event, @participant_event),
        alert: "Your role cannot edit guardian details, because it cannot see their contact details."
    end

    def set_participant_event
      @participant_event = current_event.participant_events.find(params[:participant_id])
    end

    def set_guardian_participant_event
      @guardian_participant_event = @participant_event.guardian_participant_events.find(params[:id])
    end

    def guardian_params
      params.require(:guardian).permit(
        :legal_first_name, :legal_last_name, :email, :phone,
        :address_line_1, :address_line_2, :city, :state, :postal_code, :country
      )
    end
  end
end
