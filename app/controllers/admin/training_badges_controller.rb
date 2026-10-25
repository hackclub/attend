module Admin
  class TrainingBadgesController < BaseController
    include AdminTrainingAuthoring

    STATUS_FILTERS = %w[current expired revoked all].freeze

    before_action :set_badge, except: [ :new, :create ]

    def show
      @filter = STATUS_FILTERS.include?(params[:status]) ? params[:status] : "current"
      awards = @badge.awards.includes(:user, :course, :awarded_by, :revoked_by).newest_first
      @awards = case @filter
      when "current" then awards.current
      when "expired" then awards.unrevoked.where(training_badge_awards: { expires_at: ..Time.current })
      when "revoked" then awards.where.not(revoked_at: nil)
      else awards
      end
    end

    def new
      @badge = TrainingBadge.new
    end

    def create
      @badge = TrainingBadge.new(badge_params)

      if @badge.save
        redirect_to admin_training_badge_path(@badge), notice: "Badge created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      @badge.image.purge_later if params.dig(:training_badge, :remove_image) == "1"

      if @badge.update(badge_params)
        redirect_to admin_training_badge_path(@badge), notice: "Badge updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      if @badge.destroy
        redirect_to admin_training_path, notice: "Badge deleted."
      else
        redirect_to admin_training_badge_path(@badge), alert: "This badge has been awarded, so it can't be deleted."
      end
    end

    private

    def set_badge
      @badge = TrainingBadge.with_attached_image.find(params[:id])
      @record = @badge
    end

    def badge_params
      params.require(:training_badge).permit(:name, :slug, :description, :validity_months, :image, required_roles: [])
    end
  end
end
