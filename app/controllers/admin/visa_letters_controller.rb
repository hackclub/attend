module Admin
  # An event's visa letter applications, for its admins to review: approve
  # (the letter is generated and emailed), reject soft or hard, soften a
  # hard rejection, resend a letter, record what the embassy decided, and
  # offer a place at the event.
  # Applicants' details are passport-grade, so opening one is audit-logged.
  class VisaLettersController < BaseController
    before_action :set_event
    before_action :require_event_selected
    before_action :authorize_review!
    before_action :set_application, except: :index

    FILTERS = %w[pending approved letter_sent rejected all].freeze
    OUTCOMES = VisaLetterApplication.visa_outcomes.keys.freeze

    def index
      @filter = FILTERS.include?(params[:status]) ? params[:status] : "pending"
      @query = params[:q].to_s.strip
      @counts = @event.visa_letter_applications.group(:status).count

      scope = @event.visa_letter_applications.includes(:reviewed_by).order(submitted_at: :desc)
      scope = scope.where(status: @filter) unless @filter == "all"
      # Names are encrypted, so this finds a reference number or an exact email.
      if @query.present?
        scope = scope.where(reference_number: @query.upcase).or(scope.where(email: @query))
      end
      @applications = scope
    end

    def show
      AuditLog.log!(action: :view, record: @application, actor: current_user, event: @event,
        metadata: { what: "visa_letter_application" })
    end

    # The admin notes, the one thing staff edit by hand.
    def update
      @record = @application
      @application.update!(admin_notes: params.dig(:visa_letter_application, :admin_notes))
      redirect_to admin_event_visa_letter_path(@event, @application), notice: "Notes saved."
    end

    def approve_letter
      @record = @application
      @application.approve!(by: current_user, notes: params[:admin_notes])
      GenerateVisaLetterJob.perform_later(@application)
      redirect_to admin_event_visa_letter_path(@event, @application),
        notice: "Application approved successfully. The visa letter will be generated and sent."
    rescue VisaLetterApplication::InvalidTransition => e
      redirect_to admin_event_visa_letter_path(@event, @application), alert: e.message.upcase_first
    end

    def reject_letter
      @record = @application
      reason = params[:rejection_reason].presence || params[:rejection_reason_preset].presence
      type = params[:rejection_type] == "hard" ? :hard : :soft
      @application.reject!(by: current_user, reason: reason, type: type, notes: params[:admin_notes])
      VisaLetterMailer.rejected(application: @application).deliver_later
      label = @application.hard_rejected? ? "permanently rejected" : "rejected (can reapply)"
      redirect_to admin_event_visa_letter_path(@event, @application), notice: "Application #{label}. The applicant will be notified."
    rescue VisaLetterApplication::InvalidTransition => e
      redirect_to admin_event_visa_letter_path(@event, @application), alert: e.message.upcase_first
    rescue ActiveRecord::RecordInvalid
      redirect_to admin_event_visa_letter_path(@event, @application), alert: "Rejection reason is required."
    end

    def downgrade_rejection
      @record = @application
      @application.downgrade_rejection!
      VisaLetterMailer.rejection_downgraded(application: @application).deliver_later
      redirect_to admin_event_visa_letter_path(@event, @application), notice: "Rejection downgraded. The applicant can now reapply and will be notified."
    rescue VisaLetterApplication::InvalidTransition => e
      redirect_to admin_event_visa_letter_path(@event, @application), alert: e.message.upcase_first
    end

    def resend_letter
      @record = @application
      unless @application.letter_sent? && @application.letter_pdf.attached?
        redirect_to admin_event_visa_letter_path(@event, @application), alert: "Letter has not been sent yet."
        return
      end

      VisaLetterMailer.letter_ready(application: @application).deliver_later
      redirect_to admin_event_visa_letter_path(@event, @application), notice: "Visa letter has been resent to #{@application.email}."
    end

    def record_visa_outcome
      @record = @application
      outcome = params[:visa_outcome].to_s
      unless OUTCOMES.include?(outcome)
        redirect_to admin_event_visa_letter_path(@event, @application), alert: "Choose what the embassy decided."
        return
      end

      @application.record_visa_outcome!(outcome)
      redirect_to admin_event_visa_letter_path(@event, @application), notice: "Visa outcome saved."
    rescue VisaLetterApplication::InvalidTransition => e
      redirect_to admin_event_visa_letter_path(@event, @application), alert: e.message.upcase_first
    end

    # Registers them for the event and invites them to onboard. Usually once
    # the visa is granted; earlier needs `override`, which the page only sends
    # after a confirmation saying why it's early.
    def offer_place
      @record = @application
      authorize @event, :invite_participants?
      onboarding = @application.offer_place!(override: params[:override] == "1") do |participant|
        # Another event's records may rely on these (age checks use the
        # birthday), so it's logged like any other edit to them.
        AuditLog.log!(action: :record_update, record: participant, actor: current_user, event: @event,
          changed_fields: AuditLog.redact_encrypted_fields(participant, participant.previous_changes.except("created_at", "updated_at")))
      end
      # Only once it's committed: see Invitation#deliver_later.
      onboarding&.deliver_later

      notice = if onboarding.nil?
        "They were already registered, so the application is now linked to their registration."
      elsif @event.onboarding_invites_held?
        "Place offered. Their invitation is held until you release the event's invitations."
      else
        "Place offered. They've been emailed an invitation to onboard."
      end
      redirect_to admin_event_visa_letter_path(@event, @application), notice: notice
    rescue VisaLetterApplication::InvalidTransition => e
      redirect_to admin_event_visa_letter_path(@event, @application), alert: e.message.upcase_first
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_event_visa_letter_path(@event, @application), alert: "Couldn't offer a place: #{e.record.errors.full_messages.to_sentence}."
    end

    def letter
      unless @application.letter_pdf.attached?
        redirect_to admin_event_visa_letter_path(@event, @application), alert: "There's no letter yet."
        return
      end

      send_data @application.letter_pdf.download, filename: @application.letter_pdf.filename.to_s,
        type: "application/pdf", disposition: "attachment"
    end

    private

    def set_event
      @event = Event.find_by!(slug: params[:event_slug])
    end

    def authorize_review!
      authorize @event, :review_visa_letters?
    end

    def set_application
      @application = @event.visa_letter_applications.find(params[:id])
    end
  end
end
