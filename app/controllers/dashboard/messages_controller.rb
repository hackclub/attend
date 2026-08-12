class Dashboard::MessagesController < ApplicationController
  before_action :authenticate_user!
  before_action :require_participant

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

    @grouped_deliveries = deliveries.group_by(&:message_id).map do |_message_id, group|
      {
        deliveries: group,
        message: group.first.message,
        participant_event: group.first.participant_event,
        channels: group.map(&:channel).uniq.sort,
        delivered_at: group.map(&:delivered_at).max,
        unread: group.any? { |d| !d.read? }
      }
    end.sort_by { |g| g[:delivered_at] }.reverse

    @events = Event.joins(:messages)
      .joins("INNER JOIN message_deliveries ON message_deliveries.message_id = messages.id")
      .where(message_deliveries: { id: current_deliveries.select(:id) })
      .distinct
      .order(:name)
  end

  def show
    @delivery = current_deliveries
      .includes(message: [ :event, :sent_by_user ])
      .find(params[:id])
    @message = @delivery.message
    @event = @message.event

    # Get all channels this message was delivered through
    @channels = current_deliveries.where(message: @message).pluck(:channel).uniq.sort

    # Mark all deliveries for this message as read
    current_deliveries.where(message: @message).unread.update_all(read_at: Time.current)
  end

  private

  def require_participant
    @participant = current_user.participant

    if @participant.nil?
      redirect_to onboarding_path, alert: "Please complete your profile first."
    end
  end

  def current_deliveries
    MessageDelivery
      .where(participant_event: @participant.participant_events)
      .where(status: "delivered")
  end
end
