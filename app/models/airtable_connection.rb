# An event's OAuth grant to Airtable, replacing the personal access token an
# organiser used to paste in. Tokens are encrypted and there's no paper trail:
# versions would copy them out of the encrypted columns.
class AirtableConnection < ApplicationRecord
  self.implicit_order_column = "created_at"

  # Refresh a little early so a token can't expire halfway through a sync.
  REFRESH_MARGIN = 5.minutes

  belongs_to :event
  belongs_to :connected_by, class_name: "User", optional: true

  encrypts :access_token, :refresh_token

  validates :access_token, :refresh_token, :access_token_expires_at, :refresh_token_expires_at, presence: true

  def self.attributes_from_token(token)
    {
      access_token: token.access_token,
      refresh_token: token.refresh_token,
      scope: token.scope,
      access_token_expires_at: token.expires_at,
      refresh_token_expires_at: token.refresh_expires_at
    }
  end

  # Airtable rotates the refresh token on every use and the old one stops
  # working, so two jobs refreshing at once would leave the loser holding a
  # dead token — and the connection broken for good. The row lock serialises
  # them; whoever waited re-reads the row and finds a fresh token already.
  def fresh_access_token!
    if refresh_token_expires_at.past?
      raise Airtable::AuthenticationError, "The Airtable connection expired after 60 days without a sync. Reconnect Airtable on the integrations page."
    end
    return access_token unless access_token_expiring?

    with_lock do
      if access_token_expiring?
        token = Airtable::Oauth.new.refresh(refresh_token)
        update!(self.class.attributes_from_token(token).merge(scope: token.scope.presence || scope))
      end
    end
    access_token
  end

  def base_granted?(base_id)
    bases.any? { |base| base["id"] == base_id }
  end

  def account_label
    airtable_email.presence || airtable_user_id
  end

  private

  def access_token_expiring?
    access_token_expires_at < REFRESH_MARGIN.from_now
  end
end
