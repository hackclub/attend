class AddSignerStatusToConsents < ActiveRecord::Migration[8.1]
  def change
    add_column :consents, :guardian_signed_at, :datetime
    add_column :consents, :participant_signed_at, :datetime
    add_column :consents, :pending_on, :string
  end
end
