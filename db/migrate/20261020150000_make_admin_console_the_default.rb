# The console redesign stops being opt-in: every staff member gets it, and the
# "Switch back" link in its banner is how someone returns to the original
# admin (Admin::ConsoleBetaController).
#
# Existing rows are flipped too, so staff who never opted in land on the
# console like new accounts do. Anyone who had switched back is moved over as
# well; it's one click to switch back again.
class MakeAdminConsoleTheDefault < ActiveRecord::Migration[8.1]
  def up
    change_column_default :users, :admin_console_beta, from: false, to: true
    execute "UPDATE users SET admin_console_beta = TRUE WHERE admin_console_beta = FALSE"
  end

  def down
    change_column_default :users, :admin_console_beta, from: true, to: false
  end
end
