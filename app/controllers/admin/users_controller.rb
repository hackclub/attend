module Admin
  class UsersController < BaseController
    before_action :require_global_admin
    before_action :set_user, only: [ :show, :edit, :update ]

    def index
      scope = User.all

      if params[:search].present?
        scope = scope.where("email ILIKE :term OR name ILIKE :term", term: search_like(params[:search]))
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

      # Someone who has never signed in has no User row at all, so a search by
      # their address comes back empty even though Attend knows exactly who
      # they are — imported participants complete a whole registration via the
      # guardian portal without ever holding an account. Surface those matches
      # so the lookup doesn't dead-end. Skipped when filtering by role, which
      # only exists on User.
      @unlinked_participants =
        if params[:search].present? && params[:role].blank?
          unlinked_participants_matching(search_like(params[:search]))
        else
          []
        end
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

    def search_like(term)
      "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
    end

    UNLINKED_PARTICIPANT_LIMIT = 25

    def unlinked_participants_matching(term)
      # `user_id` only gets filled in when someone runs through onboarding, so a
      # null there doesn't mean "no account" — the person may well have signed
      # in and be listed in the table above. Match on the email instead, or the
      # panel ends up telling admins nobody signed in right below the account
      # that did.
      Participant.where(user_id: nil)
        .where.not(
          "EXISTS (SELECT 1 FROM users WHERE LOWER(users.email) = LOWER(participants.email))"
        )
        .where(
          "email ILIKE :term OR preferred_name ILIKE :term " \
          "OR CONCAT(legal_first_name, ' ', legal_last_name) ILIKE :term",
          term: term
        )
        .includes(participant_events: :event)
        .order(:email)
        .limit(UNLINKED_PARTICIPANT_LIMIT)
        .to_a
    end

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
