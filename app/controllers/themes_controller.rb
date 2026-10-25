class ThemesController < ApplicationController
  skip_before_action :require_participant, raise: false

  def update
    theme = params[:theme].to_s
    # "system" is the admin console's follow-the-OS mode. It isn't one of the
    # app themes, so pages outside the console render it as light.
    theme = "light" unless ApplicationHelper::THEMES.key?(theme) || theme == ConsoleHelper::SYSTEM_THEME

    cookies.permanent[:attend_theme] = { value: theme, same_site: :lax }

    if user_signed_in? && current_user.respond_to?(:theme)
      current_user.update_column(:theme, theme)
    end

    respond_to do |format|
      format.json { render json: { theme: theme } }
      format.html { redirect_back fallback_location: root_path, notice: "Theme updated." }
    end
  end
end
