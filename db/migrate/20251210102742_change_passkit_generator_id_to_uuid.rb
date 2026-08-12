class ChangePasskitGeneratorIdToUuid < ActiveRecord::Migration[8.1]
  def up
    remove_index :passkit_passes, name: 'index_passkit_passes_on_generator', if_exists: true

    remove_column :passkit_passes, :generator_id
    add_column :passkit_passes, :generator_id, :uuid

    add_index :passkit_passes, [ :generator_type, :generator_id ], name: 'index_passkit_passes_on_generator'
  end

  def down
    remove_index :passkit_passes, name: 'index_passkit_passes_on_generator'

    remove_column :passkit_passes, :generator_id
    add_column :passkit_passes, :generator_id, :bigint

    add_index :passkit_passes, [ :generator_type, :generator_id ], name: 'index_passkit_passes_on_generator'
  end
end
