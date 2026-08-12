class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  skip_forgery_protection only: :failure

  def hack_club
    @user = User.from_omniauth(request.env["omniauth.auth"])

    if @user.persisted?
      sign_in @user, event: :authentication
      if @user.previous_email_at_sign_in.present?
        flash[:email_changed] = {
          previous_email: @user.previous_email_at_sign_in,
          current_email: @user.email
        }
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
    redirect_to root_path, alert: "Authentication failed. Please try again."
  end

  private

  def after_sign_in_path
    # If there's a pending invitation, redirect to onboarding with the invite token
    if session[:invitation_token].present?
      onboarding_path(invite: session[:invitation_token])
    elsif (stored = stored_location_for(:user))
      stored
    elsif @user.global_admin? || @user.event_role_assignments.exists?
      admin_root_path
    elsif @user.participant.present?
      dashboard_path
    else
      root_path
    end
  end
end
