module Training
  class AwardsController < BaseController
    before_action :set_award
    before_action :require_holder, except: :show

    def show
    end

    # Only a current badge can start being shared. A link that's already out
    # keeps working after a revoke or expiry — it then says so, which is the
    # point of verifying.
    def share
      unless @award.current?
        redirect_to training_award_path(@award), alert: "Only a current badge can be shared."
        return
      end

      @award.share!
      redirect_to training_award_path(@award, anchor: "share"), notice: "Your verification link is on. Anyone with it can check this badge."
    end

    def unshare
      @award.unshare!
      redirect_to training_award_path(@award, anchor: "share"), notice: "Sharing is off. The old link no longer works."
    end

    # LinkedIn's add-to-profile form needs the verification link, so adding
    # the badge there turns sharing on first.
    def linkedin
      unless @award.current?
        redirect_to training_award_path(@award), alert: "Only a current badge can be added to LinkedIn."
        return
      end

      @award.share!
      redirect_to helpers.linkedin_add_to_profile_url(@award), allow_other_host: true
    end

    private

    def set_award
      scope = current_user.global_admin? ? TrainingBadgeAward.all : current_user.training_badge_awards
      @award = scope.includes(:course, :user, badge: { image_attachment: :blob }).find(params[:id])
    end

    # Admins can look at anyone's badge, but only its holder decides whether
    # it's public.
    def require_holder
      return if @award.user_id == current_user.id

      redirect_to training_award_path(@award), alert: "Only the badge holder can change how it's shared."
    end
  end
end
