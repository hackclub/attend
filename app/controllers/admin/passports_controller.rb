module Admin
  class PassportsController < BaseController
    skip_after_action :log_admin_action
    before_action :require_global_admin
    before_action :set_user
    before_action :set_passport, only: [ :confirm, :destroy ]

    def create
      @passport = Passport.ensure_pending_for!(@user)

      render json: {
        id: @passport.id,
        token: @passport.token,
        serial_number: @passport.serial_number,
        confirm_url: confirm_admin_user_passport_path(@user, @passport)
      }, status: :created
    end

    def confirm
      @passport.confirm!(presented_token: params[:passport_token], actor: current_user)
      log_passport_action("passport_pair")

      render json: {
        success: true,
        serial_number: @passport.serial_number,
        paired_at: @passport.paired_at.iso8601
      }
    rescue Passport::TokenMismatch
      render json: { error: "Passport token mismatch" }, status: :unprocessable_entity
    rescue Passport::InvalidState
      render json: { error: "Passport is not pending" }, status: :unprocessable_entity
    end

    def destroy
      @passport.revoke!(actor: current_user)
      log_passport_action("passport_revoke")

      redirect_to admin_user_path(@user), notice: "Passport #{@passport.serial_number} revoked."
    rescue Passport::InvalidState
      redirect_to admin_user_path(@user), alert: "Only active passports can be revoked."
    end

    private

    def require_global_admin
      return if current_user.global_admin?

      redirect_to admin_root_path, alert: "Only global admins can manage passports."
    end

    def set_user
      @user = User.find(params[:user_id])
    end

    def set_passport
      @passport = @user.passports.find(params[:id])
    end

    def log_passport_action(action)
      AuditLog.log!(
        action: action,
        record: @passport,
        actor: current_user,
        changed_fields: {},
        metadata: {
          serial_number: @passport.serial_number,
          user_id: @user.id
        }
      )
    end
  end
end
