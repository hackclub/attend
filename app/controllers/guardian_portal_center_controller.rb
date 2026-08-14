class GuardianPortalCenterController < ApplicationController
  skip_before_action :set_current_attributes

  CODE_VALIDITY = 10.minutes
  SESSION_VALIDITY = 1.hour
  MAX_ATTEMPTS = 5

  # Pinned in the widget's data-action and checked against siteverify's response,
  # so a token solved on another Turnstile form cannot be replayed here.
  TURNSTILE_ACTION = "guardian_portal_code".freeze

  rate_limit to: 5, within: 15.minutes, only: :request_code,
             with: -> { redirect_to guardian_portal_center_path, alert: "Too many codes requested. Please wait a few minutes and try again." }
  rate_limit to: 10, within: 15.minutes, only: :verify,
             with: -> { redirect_to guardian_portal_center_path, alert: "Too many attempts. Please request a new code." }

  before_action :require_verified_contact, only: [ :show, :open_portal ]

  def new
    redirect_to guardian_portal_center_portals_path if verified_contact.present?
  end

  def request_code
    unless user_signed_in? || passed_turnstile?
      redirect_to guardian_portal_center_path, alert: "We couldn't verify that you're human. Please try again." and return
    end

    contact_type, contact_value = normalize_contact(params[:contact].to_s.strip)

    if contact_type.nil?
      redirect_to guardian_portal_center_path, alert: "Please enter a valid email address or phone number (including country code, e.g. +1 555 555 5555)." and return
    end

    if contact_type == "phone" && !sms_available?
      redirect_to guardian_portal_center_path, alert: "SMS verification isn't available right now — please use your email address instead." and return
    end

    code = SecureRandom.random_number(1_000_000).to_s.rjust(6, "0")
    session[:gpc_verification] = {
      "digest" => Digest::SHA256.hexdigest(code),
      "contact_type" => contact_type,
      "contact_value" => contact_value,
      "expires_at" => CODE_VALIDITY.from_now.to_i,
      "attempts" => 0
    }

    deliver_code(contact_type, contact_value, code)

    redirect_to guardian_portal_center_verify_path
  end

  def verify_form
    @pending = session[:gpc_verification]

    unless @pending.present?
      redirect_to guardian_portal_center_path, alert: "Please enter your email address or phone number first."
    end
  end

  def verify
    pending = session[:gpc_verification]

    unless pending.present?
      redirect_to guardian_portal_center_path, alert: "Please enter your email address or phone number first." and return
    end

    if Time.current.to_i > pending["expires_at"].to_i
      session.delete(:gpc_verification)
      redirect_to guardian_portal_center_path, alert: "That code has expired. Please request a new one." and return
    end

    pending["attempts"] = pending["attempts"].to_i + 1
    session[:gpc_verification] = pending

    if pending["attempts"] > MAX_ATTEMPTS
      session.delete(:gpc_verification)
      redirect_to guardian_portal_center_path, alert: "Too many incorrect attempts. Please request a new code." and return
    end

    code = params[:code].to_s.gsub(/\D/, "")

    unless code.present? && ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(code), pending["digest"].to_s)
      redirect_to guardian_portal_center_verify_path, alert: "That code doesn't match. Please check it and try again." and return
    end

    session.delete(:gpc_verification)
    session[:gpc_auth] = {
      "contact_type" => pending["contact_type"],
      "contact_value" => pending["contact_value"],
      "verified_at" => Time.current.to_i
    }

    redirect_to guardian_portal_center_portals_path
  end

  def show
    gpes = GuardianParticipantEvent
      .where(guardian_id: matching_guardians.select(:id))
      .includes(participant_event: [ :participant, :event ])

    # Withdrawn/rejected participants have nothing left for a guardian to do —
    # a pending portal for them would only dead-end on the withdrawn page.
    actionable = gpes.reject(&:completed?).reject do |gpe|
      gpe.participant_event.withdrawn? || gpe.participant_event.rejected?
    end

    @pending_portals = actionable.sort_by { |gpe| gpe.participant_event.event.starts_at || Time.current }
    @completed_portals = gpes.select(&:completed?).sort_by { |gpe| gpe.completed_at || gpe.updated_at }.reverse
  end

  # Verified guardians get a working link even when the emailed invite has
  # expired — proving ownership of the contact is a stronger check than the
  # 7-day window, so we refresh the invite's validity before redirecting.
  def open_portal
    gpe = GuardianParticipantEvent.where(guardian_id: matching_guardians.select(:id)).find(params[:id])

    token = gpe.generate_invite_token!
    gpe.update!(invite_token_sent_at: Time.current) if gpe.invite_expired?

    redirect_to guardian_portal_path(token: token)
  end

  def destroy
    session.delete(:gpc_auth)
    session.delete(:gpc_verification)
    redirect_to guardian_portal_center_path, notice: "You've been signed out of the portal center."
  end

  private

  def verified_contact
    auth = session[:gpc_auth]
    return nil if auth.blank?

    if Time.current.to_i - auth["verified_at"].to_i > SESSION_VALIDITY
      session.delete(:gpc_auth)
      return nil
    end

    auth
  end
  helper_method :verified_contact

  def require_verified_contact
    return if verified_contact.present?

    redirect_to guardian_portal_center_path, alert: "Please verify your email address or phone number to view your portals."
  end

  def matching_guardians
    auth = verified_contact

    if auth["contact_type"] == "email"
      Guardian.where("LOWER(email) = ?", auth["contact_value"].downcase)
    else
      Guardian.where(phone: auth["contact_value"])
    end
  end

  def normalize_contact(input)
    return nil if input.blank?

    if input.include?("@")
      return nil unless input.match?(URI::MailTo::EMAIL_REGEXP)

      [ "email", input.downcase ]
    else
      parsed = Phonelib.parse(input)
      return nil unless parsed.valid?

      [ "phone", parsed.e164 ]
    end
  end

  # Codes are only delivered when the contact matches a guardian on file, but
  # the response never says whether one matched — the portal center shouldn't
  # be usable to probe which emails or phone numbers we hold.
  def deliver_code(contact_type, contact_value, code)
    guardian = if contact_type == "email"
      Guardian.where("LOWER(email) = ?", contact_value).first
    else
      Guardian.find_by(phone: contact_value)
    end
    return unless guardian

    if contact_type == "email"
      GuardianMailer.portal_center_verification(email: contact_value, code: code, guardian: guardian).deliver_later
    else
      SendGuardianPortalCodeSmsJob.perform_later(contact_value, code)
    end
  end

  def sms_available?
    Setting.twilio_enabled? && TwilioService.new.configured?
  end

  # The Turnstile check gates the first code request in a session; resending a
  # code for an already-pending verification doesn't re-challenge.
  def passed_turnstile?
    return true if session[:gpc_verification].present?

    TurnstileVerifier.verify(
      params["cf-turnstile-response"],
      remote_ip: request.remote_ip,
      action: TURNSTILE_ACTION
    )
  end
end
