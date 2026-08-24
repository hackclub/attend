class MessagesToolbox < ApplicationToolbox
  AUDIENCES = Message::AUDIENCES.keys.map(&:to_s).freeze
  CHANNELS = Message::CHANNELS.keys.map(&:to_s).freeze

  tool "List an event's messages/blasts, newest first.", access: :read, scope: "messages:read" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :status, :string, "Filter by status",
      enum: %w[draft scheduled sending completed failed cancelled], optional: true
  end
  def index
    require_event!
    authorize! current_event, :update?
    scope = current_event.messages.recent
    scope = scope.where(status: params[:status]) if params[:status].present?
    render json: { event: current_event.name, messages: scope.map { |m| serialize_message(m) } }
  end

  tool "Show one message with delivery stats.", access: :read, scope: "messages:read" do
    param :message_id, :string, "Message ID"
  end
  def show
    @message = load_message!
    authorize! @message.event, :update?
    render json: serialize_message(@message, full: true)
  end

  tool "Create a draft message for an event. Does NOT send — use messages_send afterwards.",
    access: :write, scope: "messages:write" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :audience, :string, "Who to send to", enum: AUDIENCES
    param :channels, [ :string ], "Delivery channels", enum: CHANNELS
    param :body, :string, "Message body"
    param :subject, :string, "Subject (used for email)", optional: true
    param :participant_event_ids, [ :string ], "Specific registrations (when audience is specific_participants)", optional: true
    param :group_ids, [ :string ], "Group IDs (when audience is attendees_in_groups)", optional: true
    param :scheduled_at, :string, "Schedule for later (ISO8601)", optional: true
  end
  def create
    require_event!
    authorize! current_event, :update?
    @message = current_event.messages.new(
      params.permit(:audience, :body, :subject, :scheduled_at, channels: []).to_h
    )
    @message.sent_by_user = current_user
    @message.status = params[:scheduled_at].present? ? "scheduled" : "draft"
    @message.audience_filters = build_filters
    @message.save!
    render json: serialize_message(@message, full: true)
    suggests :messages_send, "Send this draft once you've reviewed it"
  end

  tool "Send (enqueue delivery for) an existing draft or scheduled message.",
    name: "send", access: :write, scope: "messages:write" do
    param :message_id, :string, "Message ID"
  end
  def send_message
    @message = load_message!
    authorize! @message.event, :update?
    unless @message.draft? || @message.scheduled?
      halt error: "Message is already #{@message.status}."
    end
    @message.update!(status: "sending")
    MessageDeliveryJob.perform_later(message_id: @message.id)
    render json: serialize_message(@message, full: true)
  end

  private

  def load_message!
    Message.find(params[:message_id]).tap do |m|
      halt error: "You don't have access to that event." unless current_user.can_access_event?(m.event)
      halt error: out_of_connection_scope(m.event) unless connection_permits_event?(m.event)
    end
  end

  def build_filters
    filters = {}
    if params[:audience] == "specific_participants" && params[:participant_event_ids].present?
      filters[:participant_event_ids] = params[:participant_event_ids]
    end
    if params[:audience] == "attendees_in_groups" && params[:group_ids].present?
      filters[:group_ids] = params[:group_ids]
    end
    filters
  end

  def serialize_message(m, full: false)
    base = { id: m.id, subject: m.subject, audience: m.audience_label,
             channels: m.channels, status: m.status, scheduled_at: m.scheduled_at, sent_at: m.sent_at }
    return base unless full

    base.merge(body: m.body, recipient_count: m.recipient_count,
               sent_count: m.sent_count, failed_count: m.failed_count,
               sent_by: m.sent_by_user&.display_name_or_fallback)
  end
end
