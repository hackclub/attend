module Admin
  class EventApiTokensController < BaseController
    skip_before_action :set_current_event_from_session

    def create
      @event = Event.find_by!(slug: params[:slug])
      authorize @event, :update?

      name = params[:name].to_s.strip
      if name.blank?
        redirect_to admin_event_integrations_path(@event), alert: "Please enter a name for the API token."
        return
      end

      token = EventApiToken.generate_for(@event, user: current_user, name: name)
      flash[:event_api_token] = token.token
      flash[:event_api_token_id] = token.id
      redirect_to admin_event_integrations_path(@event),
        notice: "API token \"#{token.name}\" created. Copy it now — it won't be shown again."
    end

    def rotate
      @event = Event.find_by!(slug: params[:slug])
      authorize @event, :update?

      token = @event.event_api_tokens.active.find(params[:id])
      token.rotate!
      flash[:event_api_token] = token.token
      flash[:event_api_token_id] = token.id
      redirect_to admin_event_integrations_path(@event),
        notice: "API token \"#{token.name}\" rotated. Copy the new value now — it won't be shown again."
    end

    def destroy
      @event = Event.find_by!(slug: params[:slug])
      authorize @event, :update?

      token = @event.event_api_tokens.active.find(params[:id])
      token.revoke!
      redirect_to admin_event_integrations_path(@event),
        notice: "API token \"#{token.name}\" revoked."
    end
  end
end
