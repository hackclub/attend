# Shows a restriction page instead of participant-facing pages to anyone on an
# active ban. Staff are exempt so a ban on someone's email can't lock them out
# of running events; admin pages live in their own namespace anyway.
module RestrictsBannedUsers
  extend ActiveSupport::Concern

  included do
    before_action :restrict_banned_user
  end

  private

  def restrict_banned_user
    return unless user_signed_in?
    return if current_user.admin? || impersonating?
    return unless Ban.user_banned?(current_user)

    render "bans/restricted", status: :forbidden
  end
end
