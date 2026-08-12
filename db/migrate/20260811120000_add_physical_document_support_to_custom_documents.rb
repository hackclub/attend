class AddPhysicalDocumentSupportToCustomDocuments < ActiveRecord::Migration[8.1]
  def change
    add_column :custom_documents, :document_kind, :string, default: "electronic", null: false
    add_column :custom_documents, :description, :text
    change_column_null :custom_documents, :docuseal_template_id, true
  end
end
