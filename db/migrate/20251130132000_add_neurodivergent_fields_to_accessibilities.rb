class AddNeurodivergentFieldsToAccessibilities < ActiveRecord::Migration[8.1]
  def change
    add_column :accessibilities, :has_adhd, :boolean
    add_column :accessibilities, :has_dyslexia, :boolean
    add_column :accessibilities, :has_autism, :boolean
    add_column :accessibilities, :neurodivergent_notes, :text
  end
end
