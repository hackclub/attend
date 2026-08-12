class AddQueryPerformanceIndexes < ActiveRecord::Migration[8.1]
  def change
    # Participant search uses leading-wildcard ILIKE ('%term%'), which btree
    # indexes cannot serve — trigram GIN indexes can (pg_trgm is already enabled).
    add_index :participants, :legal_first_name, using: :gin, opclass: :gin_trgm_ops,
              name: "index_participants_on_legal_first_name_trgm"
    add_index :participants, :legal_last_name, using: :gin, opclass: :gin_trgm_ops,
              name: "index_participants_on_legal_last_name_trgm"
    add_index :participants, :preferred_name, using: :gin, opclass: :gin_trgm_ops,
              name: "index_participants_on_preferred_name_trgm"
    add_index :participants, :email, using: :gin, opclass: :gin_trgm_ops,
              name: "index_participants_on_email_trgm"

    # Admin participant lists sort by last name.
    add_index :participants, :legal_last_name

    # User#participant (has_one) is resolved on nearly every authenticated
    # request (unread message badge, home routing) — without this it seq-scans.
    add_index :participants, :user_id

    add_index :notes, :participant_event_id
    add_index :notes, :author_user_id
    add_index :audit_logs, :actor_user_id
  end
end
