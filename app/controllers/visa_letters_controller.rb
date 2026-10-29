# Asking for a visa invitation letter, and following it up. Applicants sign in
# with their Hack Club account, but have no place at the event yet: a letter
# comes first, and staff offer a place once the visa is granted (see
# VisaLetterApplication).
#
# Who can apply for an event's letter: anyone, through its open form until
# the deadline; someone staff invited to apply (an invitation also overrides a
# hard rejection); someone whose application was soft-rejected; and anyone
# already registered for the event. Nobody, once the event has visa letters off.
class VisaLettersController < ApplicationController
  include RestrictsBannedUsers

  APPLICANT_FIELDS = %i[full_name date_of_birth nationality place_of_birth phone address].freeze

  before_action :require_sign_in, except: %i[index faq]
  # Envoy's applications move to the account with their email on any visa
  # page, so its emailed links and the apply form find them, not just the list.
  before_action :claim_imported_applications, except: :faq
  before_action :set_event, only: %i[new create]
  before_action :set_application, only: %i[show letter]

  rate_limit to: 10, within: 1.hour, only: :create, by: -> { current_user&.id || request.remote_ip },
    with: -> { redirect_to visas_path, alert: "Too many applications at once. Try again in an hour." }

  def index
    @open_events = Event.open_for_visa_letters
    return unless user_signed_in?

    @applications = current_user.visa_letter_applications.includes(:event).order(created_at: :desc)
  end

  def new
    return if redirected_to_existing_application? || refused?

    @application = @existing&.tap { |existing| existing.assign_attributes(@locked) } ||
      @event.visa_letter_applications.new(VisaLetterApplication.prefill_for(current_user))
  end

  def create
    return if redirected_to_existing_application? || refused?

    # What Hack Club Auth holds wins over anything typed into a locked field.
    attributes = applicant_params.merge(@locked)
    if @existing
      @application = @existing
      @application.resubmit!(attributes.merge(visa_letter_invitation: @invitation || @existing.visa_letter_invitation),
        overriding_hard_rejection: reinvited_after_rejection?)
    else
      @application = @event.visa_letter_applications.new(attributes.merge(
        user: current_user, email: current_user.email, visa_letter_invitation: @invitation
      ))
      unless @application.save
        render :new, status: :unprocessable_entity
        return
      end
    end

    @invitation&.claim!
    VisaLetterMailer.received(application: @application).deliver_later
    VisaLetterMailer.new_application(application: @application).deliver_later
    redirect_to visas_application_path(@application), notice: "Your application has been submitted!"
  rescue ActiveRecord::RecordInvalid
    render :new, status: :unprocessable_entity
  end

  def show
  end

  # Envoy's FAQ, for anyone, signed in or not.
  def faq
  end

  def letter
    unless @application.letter_sent? && @application.letter_pdf.attached?
      redirect_to visas_application_path(@application), alert: "Letter has not been sent yet."
      return
    end

    send_data @application.letter_pdf.download, filename: @application.letter_pdf.filename.to_s,
      type: "application/pdf", disposition: "attachment"
  end

  private

  # Signed-out visitors see what they're signing in for, then come back here.
  def require_sign_in
    return if user_signed_in?

    # Only a page to come back to, never a form submission to replay.
    store_location_for(:user, request.fullpath) if request.get? || request.head?
    @event = Event.find_by(slug: params[:event_slug]) if params[:event_slug]
    render :sign_in, status: :unauthorized
  end

  def claim_imported_applications
    VisaLetterApplication.claim_imported_for(current_user) if user_signed_in?
  end

  def set_event
    @event = Event.find_by!(slug: params[:event_slug])
    @existing = @event.visa_letter_applications.find_by(user: current_user)
    @invitation = invitation_for_this_person
    @locked = VisaLetterApplication.locked_by_hack_club_auth(current_user)
  end

  def set_application
    @application = current_user.visa_letter_applications.find(params[:id])
    @event = @application.event
  end

  def invitation_for_this_person
    token = params[:invite].presence
    return if token.blank?

    invitation = @event.visa_letter_invitations.find_by(token: token)
    return if invitation.nil?
    # Sent to someone else's address: they're told, and it doesn't count.
    unless invitation.email.casecmp?(current_user.email.to_s)
      @invitation_for = invitation.email
      return
    end
    # Used by another application already.
    return if invitation.claimed? && invitation.visa_letter_application&.user_id != current_user.id

    invitation
  end

  # Staff inviting someone again after a hard rejection is what reopens it.
  # The invitation they first applied with, or any other last sent before the
  # rejection, doesn't: otherwise following the old link would undo it.
  # Re-sending an invitation touches it (Admin::VisaLetterInvitationsController).
  # Envoy's rejections may have no review time, so their submission stands in.
  def reinvited_after_rejection?
    rejected_at = @existing&.reviewed_at || @existing&.submitted_at
    @invitation.present? && rejected_at.present? && @invitation.updated_at > rejected_at
  end

  # Their place at the event, if they already have one.
  def registration
    return @registration if defined?(@registration)

    participant = current_user.participant
    @registration = participant && participant.participant_events
      .where(event: @event).where.not(status: %w[withdrawn rejected]).first
  end

  # An application under review or with its letter has a page of its own.
  def redirected_to_existing_application?
    return false if @existing.nil? || @existing.rejected?

    if request.post?
      redirect_to visas_application_path(@existing), alert: "An application for this email already exists for this event. Please check your email for status updates."
    else
      redirect_to visas_application_path(@existing)
    end
    true
  end

  def refused?
    reason = refusal_reason
    return false if reason.nil?

    @refusal = reason
    render :closed, status: :forbidden
    true
  end

  def refusal_reason
    return :off unless @event.visa_letters_enabled?
    return :hard_rejected if @existing&.hard_rejected? && !reinvited_after_rejection?
    # A soft rejection told them to apply again, so the form's state doesn't matter.
    return nil if @existing&.soft_rejected? || @invitation || registration || @event.accepting_visa_letter_applications?

    @invitation_for ? :wrong_account : :not_open
  end

  def applicant_params
    params.require(:visa_letter_application).permit(*APPLICANT_FIELDS)
  end
end
