class AddInviteLastUsedAtToGuardianParticipantEvents < ActiveRecord::Migration[8.0]
  def up
    add_column :guardian_participant_events, :invite_last_used_at, :datetime

    # Guardians already part-way through a portal would otherwise be measured
    # against the original send date and lock out the moment this deploys.
    # Seeding from accepted_at gives them the window their activity earned.
    execute(<<~SQL)
      UPDATE guardian_participant_events
      SET invite_last_used_at = accepted_at
      WHERE accepted_at IS NOT NULL
    SQL
  end

  def down
    remove_column :guardian_participant_events, :invite_last_used_at
  end
end
