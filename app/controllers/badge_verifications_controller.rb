# Public verification of a training badge, for anyone the holder sends the
# link to — an employer, an event partner. No authentication: only awards
# whose holder turned sharing on resolve, and the page shows the badge's live
# state, so a revoked or expired one says so wherever the link was posted.
class BadgeVerificationsController < ApplicationController
  skip_before_action :set_current_attributes

  def show
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
    @award = TrainingBadgeAward.includes(:user, :course, badge: { image_attachment: :blob })
      .find_by(share_token: params[:token].to_s)
    render :not_found, status: :not_found if @award.nil?
  end
end
