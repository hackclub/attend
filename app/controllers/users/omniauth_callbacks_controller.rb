class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  skip_forgery_protection only: :failure

  # How long after someone presses a "refresh from your Hack Club account"
  # button its round trip through Hack Club Auth still counts as theirs.
  REFRESH_WINDOW = 15.minutes

  def hack_club
    auth = request.env["omniauth.auth"]
    # Before signing anyone in: a refresh comes back as the Hack Club account
    # of whoever is still signed in here. Anything else, such as HCA being
    # signed in as somebody else, is an ordinary sign-in.
    refresh = refresh_in_progress
    return_to = local_path(refresh["return_to"]) if refresh && same_hack_club_account?(auth)
    @user = User.from_omniauth(auth)

    if @user.persisted?
      sign_in @user, event: :authentication
      if @user.previous_email_at_sign_in.present?
        flash[:email_changed] = {
          previous_email: @user.previous_email_at_sign_in,
          current_email: @user.email
        }
      end
      if return_to
        redirect_to return_to, notice: "Updated from your Hack Club account."
        return
      end
      set_flash_message(:notice, :success, kind: "Hack Club Auth") if is_navigational_format?
      redirect_to after_sign_in_path
    else
      session["devise.hack_club_data"] = request.env["omniauth.auth"].except(:extra)
      redirect_to root_path, alert: "Could not authenticate you from Hack Club."
    end
  end

  def failure
    error = request.env["omniauth.error"]
    if error
      Rails.logger.error "OmniAuth failure: #{error.class} - #{error.message}"
      Rails.logger.error "OmniAuth error inspect: #{error.inspect}"
    end
    Rails.logger.error "OmniAuth error type: #{request.env['omniauth.error.type']}"
    Rails.logger.error "OmniAuth error strategy: #{request.env['omniauth.error.strategy']&.name}"
    # Someone who gave up on a refresh, or declined to share something new,
    # is still signed in, so goes back to what they were filling in.
    if (refresh = refresh_in_progress) && (return_to = local_path(refresh["return_to"]))
      redirect_to return_to, alert: "Couldn't refresh from your Hack Club account, so nothing has changed. Please try again."
    else
      redirect_to root_path, alert: "Authentication failed. Please try again."
    end
  end

  private

  # The round trip a "refresh from your Hack Club account" button started
  # (see OmniAuth::Strategies::HackClub#remember_refresh), when it's this
  # one: started by whoever is signed in now, within REFRESH_WINDOW. Read
  # once, so an abandoned refresh can't steer a later sign-in.
  def refresh_in_progress
    refresh = session.delete(OmniAuth::Strategies::HackClub::REFRESH_SESSION_KEY)
    return unless refresh.is_a?(Hash) && current_user

    refresh if refresh["user_id"] == current_user.id && refresh["at"].to_i > REFRESH_WINDOW.ago.to_i
  end

  def same_hack_club_account?(auth)
    current_user.hack_club_account_id.present? && current_user.hack_club_account_id == auth.uid
  end

  # A path on Attend, or nil. url_from turns away other hosts and anything
  # that isn't a valid URL, which redirect_to would refuse with an error
  # once sign-in has already happened.
  def local_path(location)
    path = url_from(location.to_s)
    path if path&.start_with?("/")
  end

  def after_sign_in_path
    # If there's a pending invitation, redirect to onboarding with the invite token
    if session[:invitation_token].present?
      onboarding_path(invite: session[:invitation_token])
    elsif (stored = stored_location_for(:user))
      stored
    else
      landing_path_for(@user) || root_path
    end
  end
end
