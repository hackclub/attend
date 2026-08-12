class AddDocusealFreedomWaiverTemplateIdToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :docuseal_freedom_waiver_template_id, :string
  end
end
