class AddSupportEmailToEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :events, :support_email, :string
  end
end
