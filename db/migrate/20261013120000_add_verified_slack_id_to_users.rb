class AddVerifiedSlackIdToUsers < ActiveRecord::Migration[8.1]
  # The Slack ID Hack Club Auth vouches for lives inside the encrypted
  # oidc_claims blob, so finding someone by it meant decrypting every
  # candidate in Ruby. A Slack ID isn't secret, so it gets its own plain,
  # indexed column, kept in step with the claims on every save.
  def up
    add_column :users, :verified_slack_id, :string
    add_index :users, :verified_slack_id

    User.reset_column_information
    User.where.not(oidc_claims: nil).find_each do |user|
      slack_id = User.verified_slack_id_from(user.oidc_claims)
      user.update_column(:verified_slack_id, slack_id) if slack_id
    rescue ActiveRecord::Encryption::Errors::Decryption => e
      # A row that won't decrypt must not crash-loop the deploy; it fills in
      # on that person's next sign-in instead.
      say "Skipped user #{user.id}: #{e.class}"
    end
  end

  def down
    remove_column :users, :verified_slack_id
  end
end
