class AddBodyToEmailLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :email_logs, :body, :text
  end
end
