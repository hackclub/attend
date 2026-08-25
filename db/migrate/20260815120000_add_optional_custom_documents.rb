class AddOptionalCustomDocuments < ActiveRecord::Migration[8.1]
  def change
    # Optional documents cover opt-in activities (zip lining, a hike). They
    # only exist for a participant once that participant adds them, so
    # guardians are never shown a waiver for something their child isn't doing.
    add_column :custom_documents, :optional, :boolean, default: false, null: false

    # The consent row is the opt-in record for an optional document; these
    # timestamps say when the participant added it and, if they changed their
    # mind, when they backed out. Withdrawn consents are kept rather than
    # deleted so an already-collected signature stays on file.
    add_column :consents, :opted_in_at, :datetime
    add_column :consents, :withdrawn_at, :datetime
  end
end
