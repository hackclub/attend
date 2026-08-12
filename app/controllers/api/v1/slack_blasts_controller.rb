module Api
  module V1
    class SlackBlastsController < BaseController
      before_action :set_event
      before_action :require_event_access

      def index
        slack_blasts = @event.slack_blasts
          .includes(:sent_by_user)
          .order(created_at: :desc)

        render json: {
          slack_blasts: slack_blasts.map { |blast| slack_blast_json(blast) }
        }
      end

      def show
        slack_blast = @event.slack_blasts.includes(:sent_by_user).find(params[:id])

        render json: {
          slack_blast: slack_blast_json(slack_blast)
        }
      end

      def create
        message = params[:message]&.strip

        if message.blank?
          return render json: { error: "Message cannot be blank" }, status: :unprocessable_entity
        end

        participant_events = @event.participant_events
          .joins(:participant)
          .where.not(participants: { slack_user_id: [ nil, "" ] })
          .where(status: :complete)

        if participant_events.none?
          return render json: { error: "No participants with linked Slack accounts" }, status: :unprocessable_entity
        end

        slack_blast = SlackBlast.create!(
          event: @event,
          sent_by_user: current_user,
          message: message,
          recipient_count: participant_events.count,
          status: :pending
        )

        participant_events.find_each do |pe|
          slack_blast.slack_blast_recipients.create!(
            participant_event: pe,
            status: :pending
          )
        end

        SlackBlastJob.perform_later(slack_blast_id: slack_blast.id)

        render json: {
          slack_blast: slack_blast_json(slack_blast)
        }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def set_event
        @event = Event.find(params[:event_id])
      end

      def require_event_access
        require_event_access!(@event)
      end

      def slack_blast_json(blast)
        {
          id: blast.id,
          message: blast.message,
          status: blast.status,
          recipient_count: blast.recipient_count,
          sent_count: blast.sent_count,
          failed_count: blast.failed_count,
          created_at: blast.created_at.iso8601,
          sent_by: blast.sent_by_user&.name
        }
      end
    end
  end
end
