# Give MCP refresh tokens their own lifetime.
#
# Toolchest 0.3.7 stores the refresh token on the access-token row and looks it
# up through the `active` scope, so a refresh token dies the moment its 2-hour
# access token does. Any client that goes quiet for 2 hours (a laptop asleep, a
# session that never touches Attend) can't refresh and has to redo the whole
# OAuth flow.
#
# Here a refresh token stays usable for REFRESH_TOKEN_LIFETIME after its access
# token expires, unless revoked. Access tokens stay short-lived, and the
# `authenticate` hook in toolchest.rb still re-checks the user on every call,
# so an offboarded user can refresh but can't do anything with the new token.
# Disconnecting a client from the dashboard revokes every unrevoked row,
# expired or not, so it still cuts refresh off immediately.
#
# Drop this once toolchest gives refresh tokens a separate expiry.
module ToolchestRefreshWindow
  REFRESH_TOKEN_LIFETIME = 30.days

  def find_by_refresh_token(raw_refresh, mount_key: nil)
    # Upstream hashes the param unchecked, so a missing one raised a 500
    # instead of returning invalid_grant.
    return nil unless raw_refresh.is_a?(String) && raw_refresh.present?

    scope = where(revoked_at: nil, refresh_token: Digest::SHA256.hexdigest(raw_refresh))
      .where("expires_at IS NULL OR expires_at > ?", REFRESH_TOKEN_LIFETIME.ago)
    scope = scope.where(mount_key: mount_key) if mount_key
    scope.first
  end
end

Rails.application.config.to_prepare do
  unless Toolchest::OauthAccessToken.singleton_class < ToolchestRefreshWindow
    Toolchest::OauthAccessToken.singleton_class.prepend(ToolchestRefreshWindow)
  end
end
