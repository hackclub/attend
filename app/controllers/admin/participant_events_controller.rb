module Admin
  class ParticipantEventsController < BaseController
    before_action :require_event_selected
    before_action :set_participant_event

    def confirm_nfc_badge
      unless current_event.nfc_badges_enabled?
        return render json: { error: "NFC badges are not enabled for this event" }, status: :unprocessable_entity
      end

      unless @participant_event.nfc_badge_token.present?
        return render json: { error: "No NFC badge token exists for this participant" }, status: :unprocessable_entity
      end

      if params[:badge_token].present? && params[:badge_token] != @participant_event.nfc_badge_token
        return render json: { error: "Badge token mismatch" }, status: :unprocessable_entity
      end

      @participant_event.assign_nfc_badge!(user: current_user)

      AuditLog.log!(
        action: "nfc_badge_assigned",
        record: @participant_event,
        actor: current_user,
        event: current_event,
        changed_fields: {},
        metadata: {
          participant_name: @participant_event.participant.display_name,
          badge_token: @participant_event.nfc_badge_token
        }
      )

      render json: {
        success: true,
        badge_token: @participant_event.nfc_badge_token,
        assigned_at: @participant_event.nfc_badge_assigned_at.iso8601
      }
    end

    def reset_nfc_badge
      unless current_event.nfc_badges_enabled?
        return render json: { error: "NFC badges are not enabled for this event" }, status: :unprocessable_entity
      end

      old_token = @participant_event.nfc_badge_token
      @participant_event.reset_nfc_badge!

      AuditLog.log!(
        action: "nfc_badge_reset",
        record: @participant_event,
        actor: current_user,
        event: current_event,
        changed_fields: { nfc_badge_token: [ old_token, @participant_event.nfc_badge_token ] },
        metadata: {
          participant_name: @participant_event.participant.display_name,
          old_token: old_token,
          new_token: @participant_event.nfc_badge_token
        }
      )

      render json: {
        success: true,
        new_badge_token: @participant_event.nfc_badge_token
      }
    end

    private

    def set_participant_event
      @participant_event = current_event.participant_events
        .includes(:participant)
        .find(params[:id])
    end
  end
end
