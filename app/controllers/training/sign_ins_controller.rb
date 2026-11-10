module Training
  # Sign-in for training without a Hack Club account: we email a 6-digit code
  # to the address, and entering it starts a session confined to /training
  # (see TrainingSignIn). Modelled on GuardianPortalCenterController.
  class SignInsController < ApplicationController
    CODE_VALIDITY = 10.minutes
    MAX_ATTEMPTS = 5

    # Pinned in the widget's data-action and checked against siteverify's
    # response, so a token solved on another Turnstile form can't be replayed.
    TURNSTILE_ACTION = "training_sign_in_code".freeze

    rate_limit to: 5, within: 15.minutes, only: :request_code,
               with: -> { redirect_to training_sign_in_path, alert: "Too many codes requested. Please wait a few minutes and try again." }
    rate_limit to: 10, within: 15.minutes, only: :verify,
               with: -> { redirect_to training_sign_in_path, alert: "Too many attempts. Please request a new code." }

    before_action :redirect_signed_in

    def new
    end

    def request_code
      unless passed_turnstile?
        redirect_to training_sign_in_path, alert: "We couldn't verify that you're human. Please try again." and return
      end

      email = params[:email].to_s.strip.downcase
      unless email.match?(URI::MailTo::EMAIL_REGEXP)
        redirect_to training_sign_in_path, alert: "Please enter a valid email address." and return
      end

      code = SecureRandom.random_number(1_000_000).to_s.rjust(6, "0")
      session[:training_sign_in] = {
        "digest" => Digest::SHA256.hexdigest(code),
        "email" => email,
        "expires_at" => CODE_VALIDITY.from_now.to_i,
        "attempts" => 0
      }

      # Only sent when the address can sign in this way, but the response is
      # the same either way, so this can't be used to probe who's on Attend.
      user = User.find_by(email: email)
      TrainingMailer.sign_in_code(user: user, code: code).deliver_later if TrainingSignIn.eligible?(user)

      redirect_to training_sign_in_verify_path
    end

    def verify_form
      @pending = session[:training_sign_in]
      redirect_to training_sign_in_path, alert: "Please enter your email address first." if @pending.blank?
    end

    def verify
      pending = session[:training_sign_in]

      if pending.blank?
        redirect_to training_sign_in_path, alert: "Please enter your email address first." and return
      end

      if Time.current.to_i > pending["expires_at"].to_i
        session.delete(:training_sign_in)
        redirect_to training_sign_in_path, alert: "That code has expired. Please request a new one." and return
      end

      pending["attempts"] = pending["attempts"].to_i + 1
      session[:training_sign_in] = pending

      if pending["attempts"] > MAX_ATTEMPTS
        session.delete(:training_sign_in)
        redirect_to training_sign_in_path, alert: "Too many incorrect attempts. Please request a new code." and return
      end

      code = params[:code].to_s.gsub(/\D/, "")
      unless code.present? && ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(code), pending["digest"].to_s)
        redirect_to training_sign_in_verify_path, alert: "That code doesn't match. Please check it and try again." and return
      end

      session.delete(:training_sign_in)
      # Checked again: they may have been given a role, or linked a Hack Club
      # account, since the code went out.
      user = User.find_by(email: pending["email"])
      unless TrainingSignIn.eligible?(user)
        redirect_to training_sign_in_path, alert: "Please sign in with your Hack Club account." and return
      end

      return_to = session.delete(:training_return_to)
      sign_in user, event: :authentication
      session[TrainingSignIn::SESSION_KEY] = true
      redirect_to safe_training_path(return_to) || training_path, notice: "You're signed in."
    end

    private

    def redirect_signed_in
      redirect_to training_path if user_signed_in?
    end

    # The first code request in a session is challenged; resending a code for
    # one already pending isn't.
    def passed_turnstile?
      return true if session[:training_sign_in].present?

      TurnstileVerifier.verify(params["cf-turnstile-response"], remote_ip: request.remote_ip, action: TURNSTILE_ACTION)
    end

    def safe_training_path(location)
      path = url_from(location.to_s)
      path if path&.start_with?("/training")
    end
  end
end
