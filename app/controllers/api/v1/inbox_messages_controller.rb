module Api
  module V1
    # The participant's message inbox (/dashboard/messages) for the mobile app:
    # every organizer message delivered to the signed-in user's registrations,
    # one entry per message however many channels it went out on.
    #
    # Ownership is structural, as in TicketsController: deliveries are only
    # ever loaded through current_user.participant's participant_events.
    class InboxMessagesController < BaseController
      before_action :reject_api_key_auth
      before_action :require_participant!

      def index
        deliveries = current_deliveries
          .includes(message: [ :event, :sent_by_user ], participant_event: :event)
          .order(delivered_at: :desc)

        if params[:event_id].present?
          deliveries = deliveries.joins(:message).where(messages: { event_id: params[:event_id] })
        end

        if params[:q].present?
          search_term = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%"
          deliveries = deliveries.joins(:message).where(
            "messages.subject ILIKE :q OR messages.body ILIKE :q",
            q: search_term
          )
        end

        messages = deliveries.group_by(&:message_id).map do |_message_id, group|
          message = group.first.message
          {
            id: message.id,
            subject: message.subject,
            preview_text: message.body_as_plain.truncate(140),
            event: { id: message.event.id, name: message.event.name },
            ticket_id: group.first.participant_event_id,
            channels: group.map(&:channel).uniq.sort,
            delivered_at: group.map(&:delivered_at).compact.max&.iso8601,
            sender_name: message.sent_by_user&.display_name_or_fallback,
            unread: group.any? { |d| !d.read? }
          }
        end.sort_by { |m| m[:delivered_at].to_s }.reverse

        events = Event.joins(:messages)
          .joins("INNER JOIN message_deliveries ON message_deliveries.message_id = messages.id")
          .where(message_deliveries: { id: current_deliveries.select(:id) })
          .distinct
          .order(:name)

        render json: {
          messages: messages,
          unread_count: current_deliveries.unread.distinct.count(:message_id),
          events: events.map { |event| { id: event.id, name: event.name } }
        }
      end

      # Keyed by message id (what a push notification carries), not delivery
      # id. Opening it marks every delivery of the message read, as on the web.
      def show
        deliveries = current_deliveries.where(message_id: params[:id]).includes(message: [ :event, :sent_by_user ]).to_a
        return render json: { error: "Not found" }, status: :not_found if deliveries.empty?

        message = deliveries.first.message
        current_deliveries.where(message: message).unread.update_all(read_at: Time.current)

        render json: {
          message: {
            id: message.id,
            subject: message.subject,
            body_html: message.body_as_html,
            event: { id: message.event.id, name: message.event.name },
            ticket_id: deliveries.first.participant_event_id,
            channels: deliveries.map(&:channel).uniq.sort,
            delivered_at: deliveries.map(&:delivered_at).compact.max&.iso8601,
            sender_name: message.sent_by_user&.display_name_or_fallback
          }
        }
      end

      private

      # An inbox belongs to a person; an API key has none.
      def reject_api_key_auth
        return unless api_key_request?

        render json: { error: "API key is not authorized for the inbox" }, status: :forbidden
      end

      def require_participant!
        @participant = current_user&.participant
        return if @participant

        render json: { error: "No participant profile for this account" }, status: :not_found
      end

      def current_deliveries
        MessageDelivery
          .where(participant_event: @participant.participant_events)
          .where(status: "delivered")
      end
    end
  end
end
