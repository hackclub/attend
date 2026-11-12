class AddContentDigestToPasskitPasses < ActiveRecord::Migration[8.1]
  def change
    add_column :passkit_passes, :content_digest, :string
    add_column :passkit_passes, :content_updated_at, :datetime
  end
end
