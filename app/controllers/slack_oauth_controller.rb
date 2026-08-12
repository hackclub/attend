class SlackOauthController < ApplicationController
  def connect
    participant_event = ParticipantEvent.find_signed(params[:token], purpose: :slack_connect)

    if participant_event.nil?
      redirect_to slack_error_path, alert: "Invalid or expired link."
      return
    end

    slack_service = SlackService.new
    oauth_url = slack_service.authorization_url(
      participant_event_id: participant_event.id,
      redirect_uri: slack_oauth_callback_url
    )

    redirect_to oauth_url, allow_other_host: true
  end

  def callback
    slack_service = SlackService.new

    begin
      participant_event_id = slack_service.decode_state(params[:state])
      participant_event = ParticipantEvent.find(participant_event_id)

      result = slack_service.exchange_code_for_token(
        code: params[:code],
        redirect_uri: slack_oauth_callback_url
      )

      # Skip validations: pre-existing invalid data on the participant (e.g. a
      # legacy phone number) must not block linking Slack.
      participant = participant_event.participant
      participant.slack_user_id = result[:slack_user_id]
      participant.save!(validate: false)

      if participant_event.event.slack_channel_id.present?
        slack_service = SlackService.new
        slack_service.invite_to_channel(
          channel_id: participant_event.event.slack_channel_id,
          user_id: result[:slack_user_id]
        )
        redirect_to slack_success_path, notice: "Slack connected and you've been added to the event channel!"
      else
        redirect_to slack_success_path, notice: "Slack account linked successfully!"
      end
    rescue SlackService::Error => e
      Rails.logger.error("[SlackOAuth] Error: #{e.message}")
      redirect_to slack_error_path, alert: "Failed to connect Slack: #{e.message}"
    rescue ActiveRecord::RecordNotFound
      redirect_to slack_error_path, alert: "Invalid or expired link."
    end
  end

  def success
  end

  def error
  end
end
