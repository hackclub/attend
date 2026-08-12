module Admin
  class BansController < BaseController
    before_action :require_global_admin
    before_action :set_ban, only: [ :show, :edit, :update, :destroy, :revoke, :reinstate ]

    def index
      @bans = Ban.includes(:ban_emails, :created_by).order(created_at: :desc)
    end

    def show
      @affected_participants = @ban.affected_participants
    end

    def new
      @ban = Ban.new
      @ban.ban_emails.build
    end

    def create
      @ban = Ban.new(ban_params)
      @ban.created_by = current_user

      if @ban.save
        redirect_to admin_ban_path(@ban), notice: "Ban created."
      else
        @ban.ban_emails.build if @ban.ban_emails.empty?
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @ban.ban_emails.build if @ban.ban_emails.empty?
    end

    def update
      if @ban.update(ban_params)
        redirect_to admin_ban_path(@ban), notice: "Ban updated."
      else
        @ban.ban_emails.build if @ban.ban_emails.empty?
        flash.now[:alert] = @ban.errors.full_messages.to_sentence
        render :edit, status: :unprocessable_entity
      end
    end

    def revoke
      @ban.revoke!(by: current_user)
      redirect_to admin_ban_path(@ban), notice: "Ban revoked. The record is kept for history."
    end

    def reinstate
      @ban.reinstate!
      redirect_to admin_ban_path(@ban), notice: "Ban reinstated."
    end

    def destroy
      @ban.destroy
      redirect_to admin_bans_path, notice: "Ban deleted."
    end

    private

    def set_ban
      @ban = Ban.find(params[:id])
    end

    def ban_params
      params.require(:ban).permit(
        :reason,
        :expires_at,
        ban_emails_attributes: [ :id, :email, :_destroy ]
      )
    end

    def require_global_admin
      unless current_user.global_admin?
        redirect_to admin_root_path, alert: "Only global admins can manage the ban list."
      end
    end
  end
end
