module Admin
  # Issues, rotates and revokes the API keys that back the Series API.
  #
  # Owner-only, like series membership: a series key acts as an event admin on
  # every event in the series and is the only credential that can create new
  # ones (see Api::V1::Series::EventsController).
  class SeriesApiTokensController < BaseController
    skip_before_action :set_current_event_from_session

    before_action :set_series
    before_action :require_series_owner_access

    def index
      @series_api_tokens = @series.series_api_tokens.active.includes(:user).order(created_at: :desc)
    end

    def create
      name = params[:name].to_s.strip
      if name.blank?
        redirect_to admin_series_api_tokens_path(@series), alert: "Please enter a name for the API key."
        return
      end

      token = SeriesApiToken.generate_for(@series, user: current_user, name: name)
      flash[:series_api_token] = token.token
      flash[:series_api_token_id] = token.id
      redirect_to admin_series_api_tokens_path(@series),
        notice: "API key \"#{token.name}\" created. Copy it now — it won't be shown again."
    end

    def rotate
      token = @series.series_api_tokens.active.find(params[:id])
      token.rotate!
      flash[:series_api_token] = token.token
      flash[:series_api_token_id] = token.id
      redirect_to admin_series_api_tokens_path(@series),
        notice: "API key \"#{token.name}\" rotated. Copy the new value now — it won't be shown again."
    end

    def destroy
      token = @series.series_api_tokens.active.find(params[:id])
      token.revoke!
      redirect_to admin_series_api_tokens_path(@series),
        notice: "API key \"#{token.name}\" revoked."
    end

    private

    def set_series
      @series = EventSeries.find_by!(slug: params[:series_slug])
    end

    def require_series_owner_access
      return if policy(@series).manage_api_tokens?

      redirect_to admin_series_path(@series), alert: "Only series owners can manage API keys."
    end
  end
end
