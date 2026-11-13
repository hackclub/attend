# Lets admin search fold accents, so "Montreal" finds "Montréal".
class EnableUnaccent < ActiveRecord::Migration[8.1]
  def change
    enable_extension "unaccent"
  end
end
