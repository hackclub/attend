class AddAccessToTrainingCourses < ActiveRecord::Migration[8.1]
  def change
    # invite_only: only people invited by hand, or whose role at an event that
    # hasn't finished needs the badge the course awards. open: anyone signed in.
    add_column :training_courses, :access, :string, null: false, default: "invite_only"

    create_table :training_course_invitations, id: :uuid do |t|
      t.references :training_course, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :invited_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :training_course_invitations, [ :training_course_id, :user_id ], unique: true,
      name: "index_training_course_invitations_on_course_and_user"
  end
end
