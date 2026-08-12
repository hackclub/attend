class RemoveEventFromPushTokens < ActiveRecord::Migration[8.1]
  def change
    remove_reference :push_tokens, :event, null: false, foreign_key: true, type: :uuid
  end
end
