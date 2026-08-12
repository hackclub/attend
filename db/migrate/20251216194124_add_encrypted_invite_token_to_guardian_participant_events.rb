class AddEncryptedInviteTokenToGuardianParticipantEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :guardian_participant_events, :invite_token_ciphertext, :string
  end
end
