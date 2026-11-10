class ChangeRequestsToolbox < ApplicationToolbox
  # Registration change requests: what participants file from their dashboard
  # when they need a guardian replaced, their signed identity (legal name, date
  # of birth) corrected, or support. Staff review them on the admin change
  # requests page; these tools are the same review actions.

  tool "List registration change requests for an event (pending first). Kinds: guardian, " \
       "signed_identity, support.",
    access: :read, scope: "participants:read" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :status, :string, "Filter by status", enum: %w[pending approved follow_up_needed], optional: true
    param :participant_event_id, :string, "Only requests for this registration", optional: true
    param :limit, :integer, "Max results (default 50, max 200)", optional: true, default: 50
  end
  def index
    require_event!
    authorize! current_event, :show?

    scope = policy_scope(RegistrationChangeRequest)
      .joins(:participant_event)
      .where(participant_events: { event_id: current_event.id })
      .includes(:requested_by, participant_event: [ :participant, :event ])
      .pending_first
    scope = scope.where(status: params[:status]) if params[:status].present?
    scope = scope.where(participant_event_id: params[:participant_event_id]) if params[:participant_event_id].present?
    limit = params[:limit].to_i.clamp(1, 200)

    render json: {
      event: current_event.name,
      total: scope.count,
      change_requests: scope.limit(limit).map { |r| serialize_request(r) }
    }
  end

  tool "Show one change request, including the requested values.",
    access: :read, scope: "participants:read" do
    param :change_request_id, :string, "Change request ID"
  end
  def show
    load_request!
    authorize! @change_request, :show?
    render json: serialize_request(@change_request, full: true)
  end

  tool "Approve a change request and apply it (same as Approve in the admin UI). A guardian " \
       "replacement swaps the guardian, resets guardian-signed documents and emails the new guardian; " \
       "an identity change updates legal name / date of birth. The participant is emailed. If the " \
       "change can't be applied automatically the request is marked follow_up_needed instead.",
    access: :write, scope: "participants:write" do
    param :change_request_id, :string, "Change request ID"
  end
  def approve
    load_request!
    authorize! @change_request, :approve?

    # Approve updates @change_request in place; reloading it would clear the
    # previous_changes the audit log reads.
    begin
      result = RegistrationChangeRequests::Approve.call(request: @change_request, reviewer: current_user)
    rescue ArgumentError => e
      halt error: e.message
    end

    render json: serialize_request(@change_request, full: true).merge(result: result)
  end

  tool "Send a change request back to the participant asking for more information. Emails them " \
       "your message.",
    access: :write, scope: "participants:write" do
    param :change_request_id, :string, "Change request ID"
    param :staff_response, :string, "What the participant needs to do or provide"
  end
  def request_follow_up
    load_request!
    authorize! @change_request, :request_follow_up?
    halt error: "staff_response can't be blank." if params[:staff_response].blank?

    @change_request.with_lock do
      halt error: "Request has already been resolved." unless @change_request.pending?

      @change_request.update!(status: :follow_up_needed, staff_response: params[:staff_response],
        resolved_by: current_user, resolved_at: Time.current)
    end
    RegistrationCorrectionMailer.participant_follow_up(change_request: @change_request).deliver_later

    render json: serialize_request(@change_request, full: true)
  end

  private

  def load_request!
    @change_request = RegistrationChangeRequest.includes(participant_event: [ :participant, :event ])
      .find(params[:change_request_id])
    Current.event = @change_request.participant_event.event
  end

  def serialize_request(r, full: false)
    pe = r.participant_event
    data = {
      change_request_id: r.id,
      kind: r.kind,
      status: r.status,
      participant_event_id: pe.id,
      participant: participant_name(pe.participant),
      event: pe.event.name,
      created_at: r.created_at,
      resolved_at: r.resolved_at,
      url: attend_url(routes.admin_event_registration_change_request_path(event_slug: pe.event.slug, id: r.id)),
      registration_url: registration_url(pe)
    }
    return data unless full

    data.merge(
      requested_changes: redact_requested_changes(r.requested_changes),
      requester_note: r.requester_note,
      staff_response: r.staff_response,
      follow_up_reason: r.follow_up_reason
    )
  end

  # Guardian contact details and dates of birth are PII.
  def redact_requested_changes(changes)
    return changes if view_pii?

    (changes || {}).except("phone", "date_of_birth")
  end
end
