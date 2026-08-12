class AddApiKeyDigestToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :api_key_digest, :string
  end
end
