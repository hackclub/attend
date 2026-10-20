module Training
  class AwardsController < BaseController
    def show
      scope = current_user.global_admin? ? TrainingBadgeAward.all : current_user.training_badge_awards
      @award = scope.includes(:badge, :course, :user).find(params[:id])
    end
  end
end
