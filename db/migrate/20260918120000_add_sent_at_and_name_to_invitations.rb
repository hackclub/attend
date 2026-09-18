# Onboarding invitations can now be recorded before they are emailed — an
# event can hold them until series HQ releases the lot — so an invitation
# needs to know whether its email has gone out. Every invitation that exists
# today was created by the mailer at the moment it was sent, so the backfill
# stamps them all as sent when they were created.
#
# `name` keeps the greeting name given at invite time for the same reason: a
# held invitation is emailed later, from a job, with nobody around to retype it.
class AddSentAtAndNameToInvitations < ActiveRecord::Migration[8.0]
  def up
    add_column :invitations, :sent_at, :datetime
    add_column :invitations, :name, :string

    execute "UPDATE invitations SET sent_at = created_at WHERE sent_at IS NULL"
  end

  def down
    remove_column :invitations, :name
    remove_column :invitations, :sent_at
  end
end
