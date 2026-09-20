class RegistrationChangeRequestsController < ApplicationController
  CHANGE_FIELDS = {
    "signed_identity" => %w[legal_first_name legal_last_name date_of_birth],
    "guardian" => %w[legal_first_name legal_last_name email phone relationship],
    "support" => []
  }.freeze

  before_action :authenticate_user!
  before_action :load_participant_event

  def create
    if request_params[:kind] == "guardian" && !@participant_event.guardian_replacement_eligible?
      return redirect_to dashboard_event_path(@participant_event),
        alert: "A guardian can only be replaced for a minor registration with an existing guardian."
    end

    @change_request = @participant_event.registration_change_requests.build(
      requested_by: current_user,
      kind: request_params[:kind],
      staff_audience: staff_audience,
      requested_changes: permitted_changes,
      requester_note: request_params[:requester_note]
    )
    authorize @change_request

    if @change_request.save
      RegistrationCorrectionNotifications.change_request(@change_request)
      redirect_to dashboard_event_path(@participant_event), notice: "Change request submitted."
    else
      redirect_to edit_dashboard_event_correction_path(@participant_event, section: section_for_kind),
        alert: @change_request.errors.full_messages.to_sentence
    end
  end

  def show
    @change_request = policy_scope(RegistrationChangeRequest)
      .where(participant_event: @participant_event)
      .find(params[:id])
    authorize @change_request
  end

  private

  def load_participant_event
    @participant_event = current_user.participant.participant_events.includes(:event).find(params[:participant_event_id])
    @event = @participant_event.event
  end

  def request_params
    params.require(:registration_change_request).permit(
      :kind, :requester_note, :staff_audience,
      requested_changes: CHANGE_FIELDS.values.flatten.uniq
    )
  end

  def permitted_changes
    fields = CHANGE_FIELDS.fetch(request_params[:kind].to_s, [])
    # Parameters#fetch wraps a Hash default in a fresh *unpermitted* Parameters,
    # which then raises UnfilteredParameters on #to_h — so read the key and fall
    # back to a plain Hash. A support request sends no changes at all.
    changes = request_params[:requested_changes] || {}
    changes.to_h.slice(*fields)
  end

  def staff_audience
    return "event_admin" unless request_params[:kind] == "support"

    %w[operations safeguarding].include?(request_params[:staff_audience]) ? request_params[:staff_audience] : "event_admin"
  end

  def section_for_kind
    request_params[:kind] == "signed_identity" ? "contact" : request_params[:kind]
  end
end
