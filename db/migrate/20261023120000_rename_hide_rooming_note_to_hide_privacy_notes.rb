# The series setting that hid the rooming privacy note now also hides the
# health privacy notes, so its config key is renamed to match. The old key is
# copied rather than moved, so pods still on the old code (mid-rollout, or
# after a code-only revert) keep reading hide_rooming_note; a later migration
# can drop it.
class RenameHideRoomingNoteToHidePrivacyNotes < ActiveRecord::Migration[8.1]
  def up
    copy_config_key "hide_rooming_note", "hide_privacy_notes"
  end

  def down
    copy_config_key "hide_privacy_notes", "hide_rooming_note", remove_source: true
  end

  private

  def copy_config_key(from, to, remove_source: false)
    source = remove_source ? "(config - #{quote(from)})" : "config"
    execute <<~SQL.squish
      UPDATE event_series
      SET config = #{source} || jsonb_build_object(#{quote(to)}, config -> #{quote(from)})
      WHERE config ? #{quote(from)}
    SQL
  end
end
