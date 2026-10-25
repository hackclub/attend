module Admin
  # Lets a staff member switch between the console redesign (the default, the
  # +console template variants; see BaseController#set_admin_ui_variant) and
  # the original admin.
  # BaseController#authorize_admin_access already limits this to staff, and the
  # only record touched is the signed-in user's own row, so there's no Pundit
  # policy to check. BaseController#log_admin_action audit-logs the flip as an
  # update on that user.
  class ConsoleBetaController < BaseController
    def update
      @record = current_user
      # A UI preference shouldn't fail on some unrelated invalid attribute
      # (say, a legacy avatar), so validations are skipped.
      @record.update_attribute(:admin_console_beta, ActiveModel::Type::Boolean.new.cast(params[:enabled]) || false)

      redirect_back_or_to admin_root_path, status: :see_other
    end
  end
end
