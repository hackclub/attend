module Admin
  class UsersController < BaseController
    before_action :require_global_admin
    before_action :set_user, only: [ :show, :edit, :update ]

    def index
      scope = User.all

      if params[:search].present?
        search_term = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search])}%"
        scope = scope.where("email ILIKE :term OR name ILIKE :term", term: search_term)
      end

      if params[:role].present?
        scope = scope.where(global_role: params[:role])
      end

      @per_page = 50
      @total_count = scope.count
      @total_pages = [ (@total_count.to_f / @per_page).ceil, 1 ].max
      @page = (params[:page] || 1).to_i.clamp(1, @total_pages)

      @users = scope.includes(:event_role_assignments, participant: :participant_events)
        .with_attached_avatar
        .order(:email)
        .offset((@page - 1) * @per_page)
        .limit(@per_page)
    end

    def show
      @event_role_assignments = @user.event_role_assignments.includes(:event).order("events.starts_at DESC")
      @participant_events = @user.participant&.participant_events&.includes(:event)&.order("events.starts_at DESC") || []
      @passports = @user.passports.includes(:paired_by, :revoked_by).order(created_at: :desc)
    end

    def new
      @user = User.new
    end

    def create
      @user = User.new(user_create_params)

      if @user.save
        redirect_to admin_user_path(@user), notice: "User created successfully."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @event_role_assignments = @user.event_role_assignments.includes(:event).order("events.starts_at DESC")
      @participant_events = @user.participant&.participant_events&.includes(:event)&.order("events.starts_at DESC") || []
    end

    def update
      attrs = user_params
      remove_avatar = attrs.delete(:remove_avatar) == "1"
      attrs.delete(:avatar) if remove_avatar

      @user.avatar.purge if remove_avatar

      if @user.update(attrs)
        redirect_to admin_user_path(@user), notice: "User updated successfully."
      else
        flash.now[:alert] = @user.errors.full_messages.to_sentence
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def set_user
      @user = User.find(params[:id])
    end

    def user_params
      params.require(:user).permit(:global_role, :display_name, :avatar, :remove_avatar)
    end

    def user_create_params
      params.require(:user).permit(:email, :name, :global_role)
    end

    def require_global_admin
      unless current_user.global_admin?
        redirect_to admin_root_path, alert: "Only global admins can access user management."
      end
    end
  end
end
