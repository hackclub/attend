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

      old_email = @guardian.email

      participant = @participant_event.participant
      if guardian_params[:phone].present? && participant.phone.present?
        guardian_phone_e164 = PhoneNormalizer.normalize(guardian_params[:phone])
        if guardian_phone_e164 && guardian_phone_e164 == participant.phone
          @guardian.errors.add(:phone, "cannot be the same as the participant's phone number")
          render :edit, status: :unprocessable_entity
          return
        end
      end

      if @guardian.update(guardian_params)
        if @guardian.email != old_email && !@guardian_participant_event.completed?
          @guardian_participant_event.update!(invite_token_sent_at: nil)
        end

        redirect_to admin_event_participant_path(current_event, @participant_event),
          notice: "Guardian information updated successfully."
      else
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
