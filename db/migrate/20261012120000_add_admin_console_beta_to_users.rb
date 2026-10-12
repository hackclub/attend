class AddAdminConsoleBetaToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :admin_console_beta, :boolean, null: false, default: false
  end
end
