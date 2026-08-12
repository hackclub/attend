class EnablePgcryptoExtension < ActiveRecord::Migration[8.1]
  def change
    enable_extension "pgcrypto"
  end
end
