class AddOidcClaimsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :oidc_claims, :jsonb, default: {}
  end
end
