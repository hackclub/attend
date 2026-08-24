module Admin
  class ParticipantEventsController < BaseController
    before_action :require_event_selected
    before_action :set_participant_event

    def confirm_nfc_badge
      unless current_event.nfc_badges_enabled?
        return render json: { error: "NFC badges are not enabled for this event" }, status: :unprocessable_entity
      end

      owner = token_owner
      unless owner
        return render json: { error: "Participant must have a linked user to pair an NFC token" }, status: :unprocessable_entity
      end

      token = owner.nfc_tokens.pending.order(created_at: :desc).first
      unless token
        return render json: { error: "No pending NFC token exists for this participant" }, status: :unprocessable_entity
      end

      begin
        token.confirm!(presented_token: params[:badge_token], actor: current_user)
      rescue NfcToken::TokenMismatch
        return render json: { error: "Badge token mismatch" }, status: :unprocessable_entity
      end

      AuditLog.log!(
        action: "nfc_badge_assigned",
        record: token,
        actor: current_user,
        event: current_event,
        changed_fields: {},
        metadata: {
          participant_name: @participant_event.participant.display_name,
          user_id: owner.id
        }
      )

      render json: {
        success: true,
        badge_token: token.token,
        assigned_at: token.paired_at.iso8601
      }
    end

    def reset_nfc_badge
      unless current_event.nfc_badges_enabled?
        return render json: { error: "NFC badges are not enabled for this event" }, status: :unprocessable_entity
      end

      owner = token_owner
      unless owner
        return render json: { error: "Participant must have a linked user to pair an NFC token" }, status: :unprocessable_entity
      end

      owner.nfc_tokens.pending.find_each { |token| token.revoke!(actor: current_user) }
      replacement = owner.nfc_tokens.create!

      AuditLog.log!(
        action: "nfc_badge_reset",
        record: replacement,
        actor: current_user,
        event: current_event,
        changed_fields: {},
        metadata: {
          participant_name: @participant_event.participant.display_name,
          user_id: owner.id
        }
      )

      render json: {
        success: true,
        new_badge_token: replacement.token
      }
    end

    private

    def set_participant_event
      @participant_event = current_event.participant_events
        .includes(participant: :user)
        .find(params[:id])
    end

    def token_owner
      @participant_event.participant.user
    end
  end
end
