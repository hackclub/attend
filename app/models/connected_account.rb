# A participant's linked GitHub or itch.io account. The OAuth access token is
# kept (encrypted) so we can read their repos or games later; neither
# provider's token expires.
class ConnectedAccount < ApplicationRecord
  self.implicit_order_column = "created_at"

  # No paper trail: versions would copy the access token out of the
  # encrypted column.
  belongs_to :participant

  enum :provider, { github: "github", itch: "itch" }, validate: true

  encrypts :access_token

  validates :uid, :username, :access_token, :connected_at, presence: true
  validates :provider, uniqueness: { scope: :participant_id }

  def provider_name
    AccountLinking.provider_name(provider)
  end

  def profile_url
    profile["url"].presence || (github? ? "https://github.com/#{username}" : "https://#{username}.itch.io")
  end
end
