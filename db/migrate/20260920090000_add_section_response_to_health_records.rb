class AddSectionResponseToHealthRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :medicals, :section_response, :string
    add_column :dietaries, :section_response, :string
    add_column :accessibilities, :section_response, :string
  end
end
