module Admin
  class SlackBlastsController < BaseController
    before_action :require_event_selected

    def index
      authorize current_event, :update?

      @slack_blasts = current_event.slack_blasts
        .includes(:sent_by_user)
        .order(created_at: :desc)
    end

    def show
      authorize current_event, :update?

      @slack_blast = current_event.slack_blasts.find(params[:id])
      @recipients = @slack_blast.slack_blast_recipients
        .includes(participant_event: :participant)
        .order(:status, :created_at)
    end

    def new
      authorize current_event, :update?

      @participant_count = current_event.participant_events
        .joins(:participant)
        .where.not(participants: { slack_user_id: [ nil, "" ] })
        .where(status: :complete)
        .count
    end

    def create
      authorize current_event, :update?

      message = params[:message]&.strip

      if message.blank?
        redirect_to new_admin_event_slack_blast_path(current_event), alert: "Message cannot be blank."
        return
      end

      participant_events = current_event.participant_events
        .joins(:participant)
        .where.not(participants: { slack_user_id: [ nil, "" ] })
        .where(status: :complete)

      if participant_events.none?
        redirect_to new_admin_event_slack_blast_path(current_event), alert: "No participants with linked Slack accounts."
        return
      end

      slack_blast = SlackBlast.create!(
        event: current_event,
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

      redirect_to admin_event_slack_blast_path(current_event, slack_blast),
        notice: "Slack blast queued! Sending to #{participant_events.count} participants."
    end

    def retry_failed
      authorize current_event, :update?

      @slack_blast = current_event.slack_blasts.find(params[:id])
      failed_count = @slack_blast.slack_blast_recipients.failed.count

      if failed_count.zero?
        redirect_to admin_event_slack_blast_path(current_event, @slack_blast),
          alert: "No failed recipients to retry."
        return
      end

      @slack_blast.slack_blast_recipients.failed.update_all(status: "pending", error_message: nil)
      @slack_blast.update!(status: :pending)

      SlackBlastJob.perform_later(slack_blast_id: @slack_blast.id)

      redirect_to admin_event_slack_blast_path(current_event, @slack_blast),
        notice: "Retrying #{failed_count} failed recipients..."
    end

    def retry_recipient
      authorize current_event, :update?

      @slack_blast = current_event.slack_blasts.find(params[:id])
      recipient = @slack_blast.slack_blast_recipients.find(params[:recipient_id])

      unless recipient.failed?
        redirect_to admin_event_slack_blast_path(current_event, @slack_blast),
          alert: "This recipient hasn't failed."
        return
      end

      begin
        slack_service = SlackService.new
        result = slack_service.send_dm(
          user_id: recipient.participant_event.participant.slack_user_id,
          text: @slack_blast.message
        )
        recipient.update!(status: :sent, slack_message_ts: result[:ts], error_message: nil)
        @slack_blast.update_counts!

        redirect_to admin_event_slack_blast_path(current_event, @slack_blast),
          notice: "Message sent to #{recipient.participant.display_name}."
      rescue SlackService::Error => e
        recipient.update!(error_message: e.message)
        redirect_to admin_event_slack_blast_path(current_event, @slack_blast),
          alert: "Failed to send: #{e.message}"
      end
    end
  end
end
