class ChangeGuardianPiiColumnsToText < ActiveRecord::Migration[8.1]
  def change
    change_column :guardians, :phone, :text
    change_column :guardians, :address_line_1, :text
    change_column :guardians, :address_line_2, :text
    change_column :guardians, :city, :text
    change_column :guardians, :state, :text
    change_column :guardians, :postal_code, :text
    change_column :guardians, :country, :text
  end
end
