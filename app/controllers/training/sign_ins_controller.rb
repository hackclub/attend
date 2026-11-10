module Training
  # Sign-in for training without a Hack Club account: we email a 6-digit code
  # to the address, and entering it starts a session confined to /training
  # (see TrainingSignIn).
  #
  # The code and its attempt count are kept server-side in Rails.cache, keyed
  # by the address, not in the session: the session is a cookie, and replaying
  # an old copy of it would reset the count. The browser only remembers which
  # address it's signing in as.
  class SignInsController < ApplicationController
    CODE_VALIDITY = 10.minutes
    MAX_ATTEMPTS = 5
    # Codes sent to one address, from any number of browsers. With
    # MAX_ATTEMPTS that bounds guesses at an address to 25 an hour.
    MAX_SENDS_PER_HOUR = 5

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

      sends = Rails.cache.increment(cache_key(email, "sends"), 1, expires_in: 1.hour)
      if sends.nil? || sends > MAX_SENDS_PER_HOUR
        redirect_to training_sign_in_path, alert: "Too many codes requested for that address. Please wait a while and try again." and return
      end

      code = SecureRandom.random_number(1_000_000).to_s.rjust(6, "0")
      digest = Digest::SHA256.hexdigest(code)
      Rails.cache.write(cache_key(email, "code"), digest, expires_in: CODE_VALIDITY)
      Rails.cache.delete(cache_key(email, "attempts"))
      session[:training_sign_in] = { "email" => email }

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

      email = pending["email"].to_s
      digest = Rails.cache.read(cache_key(email, "code"))
      if digest.blank?
        session.delete(:training_sign_in)
        redirect_to training_sign_in_path, alert: "That code has expired. Please request a new one." and return
      end

      attempts = Rails.cache.increment(cache_key(email, "attempts"), 1, expires_in: CODE_VALIDITY)
      if attempts.nil? || attempts > MAX_ATTEMPTS
        Rails.cache.delete(cache_key(email, "code"))
        session.delete(:training_sign_in)
        redirect_to training_sign_in_path, alert: "Too many incorrect attempts. Please request a new code." and return
      end

      code = params[:code].to_s.gsub(/\D/, "")
      unless code.present? && ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(code), digest.to_s)
        redirect_to training_sign_in_verify_path, alert: "That code doesn't match. Please check it and try again." and return
      end

      Rails.cache.delete(cache_key(email, "code"))
      Rails.cache.delete(cache_key(email, "attempts"))
      session.delete(:training_sign_in)
      # Checked again: they may have been given a role, or linked a Hack Club
      # account, since the code went out.
      user = User.find_by(email: email)
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

    # Resending a code to the address this browser is already signing in as
    # isn't challenged again; any other address is.
    def passed_turnstile?
      pending_email = session.dig(:training_sign_in, "email")
      return true if pending_email.present? && pending_email == params[:email].to_s.strip.downcase

      TurnstileVerifier.verify(params["cf-turnstile-response"], remote_ip: request.remote_ip, action: TURNSTILE_ACTION)
    end

    def cache_key(email, part)
      "training_sign_in/#{Digest::SHA256.hexdigest(email)}/#{part}"
    end

    def safe_training_path(location)
      path = url_from(location.to_s)
      path if path&.start_with?("/training")
    end
  end
end
