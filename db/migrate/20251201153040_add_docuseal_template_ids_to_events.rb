class AddDocusealTemplateIdsToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :docuseal_minor_waiver_template_id, :string
    add_column :events, :docuseal_adult_waiver_template_id, :string
  end
end
