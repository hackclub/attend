class ImpersonationsController < ApplicationController
  def destroy
    impersonator = User.find_by(id: session[:impersonator_user_id])
    impersonated_user_id = current_user&.id

    if impersonator&.global_admin?
      Rails.logger.info("[Security] Impersonation ended: admin=#{impersonator.id} target=#{impersonated_user_id} ip=#{request.remote_ip}")

      session.delete(:impersonator_user_id)
      session.delete(:impersonation_started_at)
      sign_in(:user, impersonator)
      redirect_to admin_users_path, notice: "You have stopped impersonating."
    else
      redirect_to root_path, alert: "Could not restore your session."
    end
  end
end
