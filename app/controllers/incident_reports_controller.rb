class IncidentReportsController < ApplicationController
  skip_before_action :set_current_attributes

  def new
    @incident_report = IncidentReport.new
    prefill_from_user
    @events = reportable_events

    # Remember this page so signing in via Hack Club returns the user here.
    store_location_for(:user, incident_report_path) unless user_signed_in?
  end

  def create
    @incident_report = IncidentReport.new(incident_report_params)
    assign_event_choice(@incident_report, params[:event_choice])
    @incident_report.user = current_user if user_signed_in?

    unless user_signed_in? || verify_turnstile
      @events = reportable_events
      flash.now[:alert] = "Please complete the verification challenge and try again."
      return render :new, status: :unprocessable_entity
    end

    if @incident_report.save
      IncidentReportMailer.new_report(@incident_report).deliver_later
      SendIncidentReportToSlackJob.perform_later(@incident_report.id)
      SendIncidentReportConfirmationSmsJob.perform_later(@incident_report.id)
      InitiateEmergencyIncidentCallsJob.perform_later(@incident_report.id) if @incident_report.emergency?
      redirect_to incident_report_submitted_path
    else
      @events = reportable_events
      render :new, status: :unprocessable_entity
    end
  end

  def submitted
  end

  private

  def incident_report_params
    params.require(:incident_report).permit(
      :reporter_name,
      :reporter_email,
      :reporter_phone,
      :reporter_role,
      :incident_type,
      :emergency_services_called,
      :priority,
      :summary,
      :details,
      attachments: []
    )
  end

  def prefill_from_user
    return unless user_signed_in?

    @incident_report.reporter_name ||= current_user.display_name_or_fallback
    @incident_report.reporter_email ||= current_user.email
    @incident_report.reporter_phone ||= current_user.oidc_claims&.dig("phone_number")
  end

  # Active events plus events that finished within the last 6 months.
  def reportable_events
    Event
      .where("starts_at <= ?", Time.current)
      .where("ends_at >= ?", 6.months.ago)
      .order(starts_at: :desc)
  end

  # Memoized (the view calls this more than once per render, and each call
  # is otherwise a Setting SELECT). `defined?` rather than `||=` so the
  # memo also holds if the list is ever falsy.
  def custom_events
    return @custom_events if defined?(@custom_events)

    @custom_events = Setting.incident_reports_custom_event_list
  end
  helper_method :custom_events

  # The single event dropdown sends either a real event id or "custom:<name>".
  def assign_event_choice(report, choice)
    return if choice.blank?

    if choice.start_with?("custom:")
      report.custom_event_name = choice.delete_prefix("custom:")
    else
      report.event_id = choice
    end
  end

  def verify_turnstile
    TurnstileVerifier.verify(params["cf-turnstile-response"], remote_ip: request.remote_ip)
  end
end
