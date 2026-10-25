# What a scan point means for where a participant is (venue, lodging, pickup,
# an outing, departure, or tracking only), and a note on when to use it. Both
# are nullable so the deploy needs no table rewrite; the next migration fills
# in kind for existing points. checks_in and is_travel_pickup stay, and the
# model keeps them in step with kind for the API and the code that reads them.
class AddKindAndUsageNoteToScanContexts < ActiveRecord::Migration[8.1]
  def change
    add_column :scan_contexts, :kind, :string
    add_column :scan_contexts, :usage_note, :text
  end
end
