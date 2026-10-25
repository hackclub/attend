class AddScopesToGlobalApiTokens < ActiveRecord::Migration[8.1]
  # An empty array means unrestricted — every token issued before this column
  # existed keeps its full global-admin access. A non-empty array narrows the
  # token to just those scopes; see GlobalApiToken::SCOPES.
  def change
    add_column :global_api_tokens, :scopes, :string, array: true, default: [], null: false
  end
end
