class Api::V1::SlackEventsController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_forgery_protection
  skip_before_action :check_maintenance_mode
  skip_before_action :check_impersonation_timeout
  skip_before_action :set_current_attributes

  before_action :verify_slack_request, unless: -> { params[:type] == "url_verification" }

  def create
    case params[:type]
    when "url_verification"
      render json: { challenge: params[:challenge] }
    when "event_callback"
      handle_event(params[:event])
      head :ok
    else
      head :ok
    end
  end

  private

  def handle_event(event)
    return unless event[:type] == "message"
    return unless event[:thread_ts].present?
    return unless event[:text]&.start_with?("?")

    ProcessSlackIncidentReplyJob.perform_later(
      channel_id: event[:channel],
      thread_ts: event[:thread_ts],
      message_ts: event[:ts],
      user_id: event[:user],
      text: event[:text]
    )
  end

  def verify_slack_request
    signing_secret = Rails.application.credentials.dig(:slack, :signing_secret)
    return head :unauthorized if signing_secret.blank?

    timestamp = request.headers["X-Slack-Request-Timestamp"]
    signature = request.headers["X-Slack-Signature"]

    return head :unauthorized if timestamp.blank? || signature.blank?

    if (Time.now.to_i - timestamp.to_i).abs > 60 * 5
      return head :unauthorized
    end

    body = request.raw_post
    sig_basestring = "v0:#{timestamp}:#{body}"
    my_signature = "v0=" + OpenSSL::HMAC.hexdigest("SHA256", signing_secret, sig_basestring)

    unless ActiveSupport::SecurityUtils.secure_compare(my_signature, signature)
      head :unauthorized
    end
  end
end
