class AddDocusealFieldMappingsToEvents < ActiveRecord::Migration[8.0]
  def change
    add_column :events, :docuseal_field_mappings, :jsonb, default: {}, null: false
  end
end
