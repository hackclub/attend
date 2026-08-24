class AddEmailUndeliverableAtToParticipantsAndGuardians < ActiveRecord::Migration[8.1]
  def change
    add_column :participants, :email_undeliverable_at, :datetime
    add_column :guardians, :email_undeliverable_at, :datetime
  end
end
