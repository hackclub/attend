module Api
  module V1
    class NfcBadgesController < BaseController
      before_action :set_event
      before_action :require_event_access
      before_action :set_participant_event

      def ensure
        unless @event.nfc_badges_enabled?
          return render json: { error: "NFC badges are not enabled for this event" }, status: :unprocessable_entity
        end

        owner = token_owner
        unless owner
          return render json: { error: "Participant must have a linked user to pair an NFC token" }, status: :unprocessable_entity
        end

        token = NfcToken.ensure_pending_for!(owner)

        render json: {
          badge_token: token.token,
          assigned: @participant_event.nfc_badge_assigned?,
          assigned_at: @participant_event.active_nfc_token&.paired_at&.iso8601
        }
      end

      def confirm
        unless @event.nfc_badges_enabled?
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
          event: @event,
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

      def reset
        unless @event.nfc_badges_enabled?
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
          event: @event,
          changed_fields: {},
          metadata: {
            participant_name: @participant_event.participant.display_name,
            user_id: owner.id
          }
        )

        render json: {
          success: true,
          badge_token: replacement.token
        }
      end

      private

      def set_event
        @event = Event.find(params[:event_id])
      end

      def require_event_access
        require_event_access!(@event)
      end

      def set_participant_event
        @participant_event = @event.participant_events
          .includes(participant: :user)
          .find(params[:participant_event_id])
      end

      def token_owner
        @participant_event.participant.user
      end
    end
  end
end
