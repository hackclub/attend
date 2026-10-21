module Admin
  class BansController < BaseController
    before_action :require_global_admin
    before_action :set_ban, only: [ :show, :edit, :update, :destroy, :revoke, :reinstate ]

    PER_PAGE = 50
    STATUS_FILTERS = %w[active revoked expired].freeze

    def index
      scope = Ban.all

      if params[:search].present?
        term = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search].strip)}%"
        scope = scope.where(<<~SQL.squish, term: term)
          bans.reason ILIKE :term
          OR EXISTS (SELECT 1 FROM ban_emails WHERE ban_emails.ban_id = bans.id AND ban_emails.email ILIKE :term)
          OR EXISTS (SELECT 1 FROM ban_slack_ids WHERE ban_slack_ids.ban_id = bans.id AND ban_slack_ids.slack_id ILIKE :term)
        SQL
      end

      @status = params[:status].presence_in(STATUS_FILTERS)
      case @status
      when "active"  then scope = scope.active
      when "revoked" then scope = scope.where.not(revoked_at: nil)
      when "expired" then scope = scope.where(revoked_at: nil).where("bans.expires_at <= ?", Time.current)
      end

      @per_page = PER_PAGE
      @total_count = scope.count
      @total_pages = [ (@total_count.to_f / @per_page).ceil, 1 ].max
      @page = (params[:page] || 1).to_i.clamp(1, @total_pages)

      @bans = scope.includes(:ban_emails, :ban_slack_ids, :created_by)
        .order(created_at: :desc)
        .offset((@page - 1) * @per_page)
        .limit(@per_page)
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
