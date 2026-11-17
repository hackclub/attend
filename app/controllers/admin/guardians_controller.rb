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
        attributes: guardian_params,
        # This form is gated on PII access (require_contact_details_access),
        # not on manage_guardians?, so ops can correct a guardian here.
        require_policy: false)

      if result.success?
        redirect_to admin_event_participant_path(current_event, @participant_event),
          notice: "Guardian information updated successfully."
      elsif result.code == :pii_restricted
        require_contact_details_access
      elsif result.code == :nothing_to_update
        # A submission with none of the form's fields. Not an error to fix, so
        # back to the participant rather than a form with nothing wrong on it.
        redirect_to admin_event_participant_path(current_event, @participant_event),
          notice: "No changes were made to the guardian."
      else
        # @guardian carries the errors: a failed validation, or a phone number
        # that is also the participant's. A failure somewhere else (the invite
        # link) left nothing on it, so say what the operation said.
        flash.now[:alert] = result.message if @guardian.errors.empty?
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
