class CreateTrainingDisclosures < ActiveRecord::Migration[8.1]
  def change
    # A course can ask a yes/no criminal-record declaration before its first
    # lesson; the wording is editable so the Safety Team can sign it off.
    add_column :training_courses, :disclosure_required, :boolean, null: false, default: false
    add_column :training_courses, :disclosure_question, :text

    # One declaration per course attempt. The answer and the review note are
    # encrypted; review_status stays plain because eligibility is queried on
    # it ("not_required" for a no, otherwise the Safety Team's review).
    create_table :training_disclosures, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :training_course, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :training_enrollment, type: :uuid, foreign_key: { on_delete: :nullify }
      t.text :question, null: false
      t.text :answer, null: false
      t.string :review_status, null: false
      t.datetime :answered_at, null: false
      t.references :reviewed_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :reviewed_at
      t.text :review_note
      t.timestamps
    end
    add_index :training_disclosures, :review_status
  end
end
