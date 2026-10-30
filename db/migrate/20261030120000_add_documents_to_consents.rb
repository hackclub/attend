# DocuSeal templates can hold several documents, and each comes back signed as
# its own PDF. document_url only ever kept the first one.
class AddDocumentsToConsents < ActiveRecord::Migration[8.1]
  def change
    add_column :consents, :documents, :jsonb, default: [], null: false
  end
end
