# badge.hackclub.com/t/:slack_id — the QR code printed on someone's event badge.
#
# Deliberately not an ApplicationController subclass. Everything that one adds
# (Pundit, impersonation timeouts, maintenance mode, PaperTrail, the modern-
# browser gate) is about a signed-in person using Attend, and none of it should
# stand between a stranger pointing a phone camera at a badge and the link the
# badge's owner chose. `allow_browser versions: :modern` in particular would
# answer 406 to whatever old handset happens to scan it.
class BadgeRedirectsController < ActionController::Base
  # Nothing here reads or writes session state; `elsewhere` answers every verb.
  skip_forgery_protection

  layout false

  def show
    badge_redirect = BadgeRedirect.for_slack_id(params[:slack_id])

    if badge_redirect&.url.present?
      redirect_to badge_redirect.url, allow_other_host: true, status: :found
    else
      @slack_id = params[:slack_id]
      render :not_found, status: :not_found
    end
  end

  # Any other path on the badge host. The links live in Attend now, so send
  # people to the page where they can set theirs instead of serving them a
  # second copy of the app on the wrong domain.
  def elsewhere
    redirect_to AttendUrls.attend_url(
      Rails.application.routes.url_helpers.dashboard_profile_path(anchor: "badge-link")
    ), allow_other_host: true, status: :moved_permanently
  end
end
