# Deleting a user used to raise ActiveRecord::InvalidForeignKey if they had ever
# created an API token, because both token tables pointed at users with a plain
# FK and no ON DELETE action. Each table gets the action that matches what the
# token actually is:
#
# * event_api_tokens.user_id is already nullable, and the token belongs to an
#   *event* — the creator is kept for the display name and audit context only.
#   An event integration must not die because the organizer who set it up left,
#   so the reference nullifies. (series_api_tokens shipped this way already.)
#
# * global_api_tokens.user_id is NOT NULL, and GlobalApiToken validates that
#   its owner is a global admin — a check Api::V1::BaseController repeats on
#   every request. A token whose owner is gone therefore cannot authenticate
#   and cannot even be saved, so it cascades rather than lingering as a row
#   that no longer validates.
class FixApiTokenUserForeignKeys < ActiveRecord::Migration[8.0]
  def up
    remove_foreign_key :event_api_tokens, :users
    add_foreign_key :event_api_tokens, :users, on_delete: :nullify

    remove_foreign_key :global_api_tokens, :users
    add_foreign_key :global_api_tokens, :users, on_delete: :cascade
  end

  def down
    remove_foreign_key :event_api_tokens, :users
    add_foreign_key :event_api_tokens, :users

    remove_foreign_key :global_api_tokens, :users
    add_foreign_key :global_api_tokens, :users
  end
end
