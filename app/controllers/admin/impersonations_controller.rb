module Admin
  class ImpersonationsController < BaseController
    before_action :require_global_admin
    before_action :set_user, only: :create

    def create
      if @user == current_user
        redirect_back fallback_location: admin_users_path, alert: "You cannot impersonate yourself."
        return
      end

      # Store values before sign_in, as Devise resets session to prevent fixation attacks
      impersonator_id = current_user.id
      started_at = Time.current.to_i

      sign_in(:user, @user)

      # Restore impersonation data after session reset
      session[:impersonator_user_id] = impersonator_id
      session[:impersonation_started_at] = started_at

      Rails.logger.info("[Security] Impersonation started: admin=#{impersonator_id} target=#{@user.id} ip=#{request.remote_ip}")

      # Log to audit trail (impersonation is security-critical)
      AuditLog.log!(
        action: "impersonate",
        record: @user,
        actor: User.find(impersonator_id),
        event: current_event,
        changed_fields: {},
        metadata: {
          ip: request.remote_ip,
          user_agent: request.user_agent,
          target_user_id: @user.id,
          target_user_email: @user.email
        }
      )

      redirect_to root_path, notice: "You are now impersonating #{@user.name || @user.email}. Session expires in 1 hour."
    end

    private

    def set_user
      @user = User.find(params[:user_id])
    end

    def require_global_admin
      unless current_user&.global_admin?
        redirect_to root_path, alert: "Only global admins can impersonate users."
      end
    end
  end
end
