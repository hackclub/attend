module Admin
  class GlobalApiTokensController < BaseController
    before_action :require_global_admin

    def index
      @global_api_tokens = GlobalApiToken.where(user: current_user).order(created_at: :desc)
    end

    def create
      token = GlobalApiToken.generate_for(current_user, name: params[:name].presence)
      flash[:global_api_token] = token.token
      redirect_to admin_global_api_tokens_path,
        notice: "Global API token created. Copy it now — it won't be shown again."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_global_api_tokens_path, alert: e.message
    end

    def revoke
      token = GlobalApiToken.where(user: current_user).find(params[:id])
      token.revoke!
      redirect_to admin_global_api_tokens_path, notice: "Global API token revoked."
    end

    private

    def require_global_admin
      unless current_user&.global_admin?
        redirect_to admin_root_path, alert: "You must be a global admin to manage global API tokens."
      end
    end
  end
end
