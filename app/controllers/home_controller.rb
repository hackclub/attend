class HomeController < ApplicationController
  def index
    stash_post_login_return

    unless user_signed_in?
      @landing = LandingStats.fetch
      @visa_letter_events = Event.open_for_visa_letters
      return
    end

    landing = landing_path_for(current_user)
    redirect_to landing if landing
  end

  def dev_sign_in
    raise ActionController::RoutingError, "Not Found" unless Rails.env.development?

    email = params[:email]
    user = User.find_by(email: email)

    if user.nil? && params[:create_user] == "1"
      user = User.create!(
        email: email,
        name: email.split("@").first.titleize
      )
    end

    if user
      sign_in(user)
      redirect_to root_path, notice: "Signed in as #{user.email}"
    else
      redirect_to root_path, alert: "User not found: #{email}. Check the box to create a new user."
    end
  end

  private

  # Toolchest sends unauthenticated MCP OAuth clients here as
  # "/?return_to=<authorize_url>". Remember that target (Devise consumes it in
  # OmniauthCallbacksController#after_sign_in_path) so sign-in lands back on the
  # consent screen instead of the dashboard. Only same-host paths are honored,
  # stored as a relative path, so this can't be used as an open redirect.
  def stash_post_login_return
    return_to = params[:return_to]
    return if return_to.blank?

    uri = URI.parse(return_to)
    return if uri.host.present? && uri.host != request.host

    path = uri.path.to_s
    return unless path.start_with?("/")

    path += "?#{uri.query}" if uri.query.present?
    store_location_for(:user, path)
  rescue URI::InvalidURIError
    nil
  end
end
