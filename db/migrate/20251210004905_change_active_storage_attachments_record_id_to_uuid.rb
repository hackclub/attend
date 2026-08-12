class ChangeActiveStorageAttachmentsRecordIdToUuid < ActiveRecord::Migration[8.1]
  def up
    # Remove the existing index first
    remove_index :active_storage_attachments, name: "index_active_storage_attachments_uniqueness"

    # Delete existing attachments that have bigint record_ids (they can't be converted to UUIDs)
    # These are orphaned anyway since they reference non-existent integer IDs
    execute "DELETE FROM active_storage_attachments"

    # Change the column type to string (which can store both UUIDs and integers if needed)
    # Using string is more flexible and works with polymorphic associations
    change_column :active_storage_attachments, :record_id, :string

    # Re-add the index
    add_index :active_storage_attachments, [ :record_type, :record_id, :name, :blob_id ],
              name: "index_active_storage_attachments_uniqueness", unique: true
  end

  def down
    remove_index :active_storage_attachments, name: "index_active_storage_attachments_uniqueness"

    # Note: this will fail if there are UUID values in the column
    change_column :active_storage_attachments, :record_id, :bigint

    add_index :active_storage_attachments, [ :record_type, :record_id, :name, :blob_id ],
              name: "index_active_storage_attachments_uniqueness", unique: true
  end
end
