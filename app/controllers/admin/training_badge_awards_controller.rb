module Admin
  # Crediting someone with a badge by hand — for equivalent training done
  # elsewhere — and revoking an award, which keeps the row for the record.
  class TrainingBadgeAwardsController < BaseController
    include AdminTrainingAuthoring

    before_action :set_badge

    def new
      @award = @badge.awards.build(awarded_at: Time.current, expires_at: default_expiry)
    end

    def create
      email = params[:email].to_s.strip.downcase
      @award = @badge.awards.build(award_params.merge(awarded_by: current_user))

      unless email.match?(URI::MailTo::EMAIL_REGEXP)
        @award.errors.add(:base, "Enter the email address of the person to award this badge to.")
        render :new, status: :unprocessable_entity
        return
      end

      @award.user = User.find_by(email: email) || User.create!(email: email, name: email.split("@").first.titleize)
      @award.expires_at = default_expiry(@award.awarded_at) if params[:use_default_expiry] == "1"

      if @award.save
        redirect_to admin_training_badge_path(@badge), notice: "#{@badge.name} awarded to #{@award.user.email}."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def revoke
      @award = @badge.awards.find(params[:id])
      @award.revoke!(by: current_user, reason: params[:reason])
      redirect_back_or_to admin_training_badge_path(@badge), notice: "Award revoked. The record is kept for history."
    end

    private

    def set_badge
      @badge = TrainingBadge.find(params[:badge_id])
    end

    def default_expiry(from = Time.current)
      @badge.validity_months&.months&.since(from)
    end

    def award_params
      params.require(:training_badge_award).permit(:awarded_at, :expires_at, :note)
    end
  end
end
