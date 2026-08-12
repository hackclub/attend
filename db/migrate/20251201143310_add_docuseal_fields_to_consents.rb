class AddDocusealFieldsToConsents < ActiveRecord::Migration[8.1]
  def change
    add_column :consents, :docuseal_participant_slug, :string
    add_column :consents, :docuseal_guardian_slug, :string
  end
end
