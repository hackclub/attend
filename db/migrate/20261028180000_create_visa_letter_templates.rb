# The wording of the visa invitation letters Attend issues, moved here from
# Envoy (the standalone app behind visas.hackclub.com). One global default,
# which an event can override with its own. The body is plain text with
# {{placeholders}}, paragraphs separated by blank lines.
class CreateVisaLetterTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :visa_letter_templates, id: :uuid do |t|
      t.references :event, type: :uuid, foreign_key: true, index: true
      t.string :name, null: false
      t.text :body, null: false
      t.string :signatory_name, null: false
      t.string :signatory_title, null: false
      t.boolean :is_default, null: false, default: false
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :visa_letter_templates, :is_default, unique: true,
      where: "is_default AND event_id IS NULL", name: "index_visa_letter_templates_one_global_default"
  end
end
