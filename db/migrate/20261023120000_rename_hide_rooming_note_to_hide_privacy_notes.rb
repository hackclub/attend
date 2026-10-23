# The series setting that hid the rooming privacy note now also hides the
# health privacy notes, so its config key is renamed to match.
class RenameHideRoomingNoteToHidePrivacyNotes < ActiveRecord::Migration[8.1]
  def up
    rename_config_key "hide_rooming_note", "hide_privacy_notes"
  end

  def down
    rename_config_key "hide_privacy_notes", "hide_rooming_note"
  end

  private

  def rename_config_key(from, to)
    execute <<~SQL.squish
      UPDATE event_series
      SET config = (config - #{quote(from)}) || jsonb_build_object(#{quote(to)}, config -> #{quote(from)})
      WHERE config ? #{quote(from)}
    SQL
  end
end
