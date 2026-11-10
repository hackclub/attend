module Training
  # Sign-in for training without a Hack Club account: we email an 8-digit code
  # to the address, and entering it starts a session confined to /training
  # (see TrainingSignIn).
  #
  # Each code request gets a random nonce, kept in the session; the code, its
  # address and its attempt count live server-side in Rails.cache under that
  # nonce. So replaying an old copy of the session cookie can't reset the
  # attempt count, and nobody else asking for a code to the same address can
  # overwrite or burn this browser's code.
  #
  # Codes sent to one address are capped across this clock hour and the last,
  # which bounds guesses at that address to MAX_SENDS_PER_HOUR * MAX_ATTEMPTS
  # an hour however many browsers try: against an 8-digit code that's under
  # 0.25% a year of non-stop guessing, every guess costing an email to the
  # real inbox. Someone who knows an address can use up the cap, but only for
  # up to two hours, and Hack Club Auth still works meanwhile.
  class SignInsController < ApplicationController
    CODE_DIGITS = 8
    CODE_VALIDITY = 10.minutes
    MAX_ATTEMPTS = 5
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

      sends = Rails.cache.increment(sends_key(email), 1, expires_in: 2.hours)
      previous_hour = Rails.cache.read(sends_key(email, 1.hour.ago)).to_i
      if sends.nil? || sends + previous_hour > MAX_SENDS_PER_HOUR
        redirect_to training_sign_in_path, alert: "Too many codes requested for that address. Please wait a while and try again." and return
      end

      code = SecureRandom.random_number(10**CODE_DIGITS).to_s.rjust(CODE_DIGITS, "0")
      nonce = SecureRandom.urlsafe_base64(24)
      Rails.cache.write(pending_key(nonce, "code"), { "email" => email, "digest" => Digest::SHA256.hexdigest(code) }, expires_in: CODE_VALIDITY)
      session[:training_sign_in] = { "email" => email, "nonce" => nonce }

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

      nonce = pending["nonce"].to_s
      stored = nonce.present? ? Rails.cache.read(pending_key(nonce, "code")) : nil
      if stored.blank?
        session.delete(:training_sign_in)
        redirect_to training_sign_in_path, alert: "That code has expired. Please request a new one." and return
      end

      attempts = Rails.cache.increment(pending_key(nonce, "attempts"), 1, expires_in: CODE_VALIDITY)
      if attempts.nil? || attempts > MAX_ATTEMPTS
        Rails.cache.delete(pending_key(nonce, "code"))
        session.delete(:training_sign_in)
        redirect_to training_sign_in_path, alert: "Too many incorrect attempts. Please request a new code." and return
      end

      code = params[:code].to_s.gsub(/\D/, "")
      unless code.present? && ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(code), stored["digest"].to_s)
        redirect_to training_sign_in_verify_path, alert: "That code doesn't match. Please check it and try again." and return
      end

      Rails.cache.delete(pending_key(nonce, "code"))
      Rails.cache.delete(pending_key(nonce, "attempts"))
      session.delete(:training_sign_in)
      # Checked again: they may have been given a role, or linked a Hack Club
      # account, since the code went out.
      user = User.find_by(email: stored["email"])
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

    def pending_key(nonce, part)
      "training_sign_in/pending/#{nonce}/#{part}"
    end

    # A fixed bucket per clock hour, so the cap's window can't be stretched by
    # requests that keep refreshing a sliding expiry.
    def sends_key(email, at = Time.current)
      "training_sign_in/sends/#{Digest::SHA256.hexdigest(email)}/#{at.to_i / 1.hour.to_i}"
    end

    def safe_training_path(location)
      path = url_from(location.to_s)
      path if path&.start_with?("/training")
    end
  end
end
