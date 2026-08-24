class TicketsToolbox < ApplicationToolbox
  tool "List support tickets you can see, newest activity first.", access: :read, scope: "tickets:read" do
    param :status, :string, "Filter by status", enum: %w[open closed], optional: true
    param :assigned_to_me, :boolean, "Only tickets assigned to me", optional: true
    param :limit, :integer, "Max results (default 30, max 100)", optional: true, default: 30
  end
  def index
    scope = policy_scope(Ticket).recent_first.includes(:event, :assigned_to)
    scope = scope.where(status: params[:status]) if params[:status].present?
    scope = scope.where(assigned_to_id: current_user.id) if params[:assigned_to_me]
    limit = params[:limit].to_i.clamp(1, 100)
    render json: { tickets: scope.limit(limit).map { |t| serialize_ticket(t) } }
  end

  tool "Show a ticket with its full message thread.", access: :read, scope: "tickets:read" do
    param :ticket_id, :string, "Ticket ID"
  end
  def show
    @ticket = Ticket.find(params[:ticket_id])
    authorize! @ticket, :show?
    render json: serialize_ticket(@ticket, full: true)
  end

  tool "Reply to a ticket. Sends an outbound message on the ticket's channel.",
    access: :write, scope: "tickets:write" do
    param :ticket_id, :string, "Ticket ID"
    param :body, :string, "Message to send"
  end
  def reply
    @ticket = Ticket.find(params[:ticket_id])
    authorize! @ticket, :update?
    begin
      ::Support::SendTicketMessage.call(ticket: @ticket, body: params[:body], user: current_user)
    rescue ::Support::SendTicketMessage::DeliveryError => e
      halt error: "Failed to send: #{e.message}"
    end
    render json: serialize_ticket(@ticket.reload, full: true)
  end

  tool "Assign a ticket to a user (or pass no user_id to unassign).",
    access: :write, scope: "tickets:write" do
    param :ticket_id, :string, "Ticket ID"
    param :user_id, :string, "User ID to assign to (omit to unassign)", optional: true
  end
  def assign
    @ticket = Ticket.find(params[:ticket_id])
    authorize! @ticket, :assign?
    @ticket.update!(assigned_to_id: params[:user_id].presence)
    render json: serialize_ticket(@ticket)
  end

  tool "Close a ticket.", access: :write, scope: "tickets:write" do
    param :ticket_id, :string, "Ticket ID"
  end
  def close
    @ticket = Ticket.find(params[:ticket_id])
    authorize! @ticket, :close?
    @ticket.close!(user: current_user)
    render json: serialize_ticket(@ticket)
  end

  tool "Reopen a closed ticket.", access: :write, scope: "tickets:write" do
    param :ticket_id, :string, "Ticket ID"
  end
  def reopen
    @ticket = Ticket.find(params[:ticket_id])
    authorize! @ticket, :reopen?
    @ticket.reopen!
    render json: serialize_ticket(@ticket)
  end

  private

  def serialize_ticket(t, full: false)
    base = {
      id: t.id,
      status: t.status,
      channel: t.channel,
      phone_number: t.phone_number,
      event: t.event&.name,
      assigned_to: t.assigned_to&.display_name_or_fallback,
      last_message_at: t.last_message_at,
      url: ticket_url(t)
    }
    return base unless full

    base.merge(
      subject: t.subject ? { type: t.subject_type, id: t.subject_id } : nil,
      messages: t.ticket_messages.order(:created_at).map { |m|
        { direction: m.direction, body: m.body, channel: m.channel,
          from: m.user&.display_name_or_fallback, at: m.created_at, status: m.twilio_status }
      }
    )
  end
end
