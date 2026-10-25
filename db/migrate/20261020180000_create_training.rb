class CreateTraining < ActiveRecord::Migration[8.1]
  def change
    # What someone holds once they've passed a course (or been credited with
    # training done elsewhere). `required_roles` names the event roles — plus
    # "volunteer" — that must hold a current one to work an event.
    create_table :training_badges, id: :uuid do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      t.integer :validity_months
      t.string :required_roles, array: true, null: false, default: []
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :training_badges, :slug, unique: true

    create_table :training_courses, id: :uuid do |t|
      t.references :training_badge, type: :uuid, foreign_key: true
      t.string :title, null: false
      t.string :slug, null: false
      t.text :summary
      t.string :status, null: false, default: "draft"
      t.integer :pass_mark, null: false, default: 80
      t.integer :estimated_minutes
      # When a learner sees which answers were right: only once they've
      # passed (so a failed attempt can't just be copied), or after every one.
      t.string :reveal_answers, null: false, default: "after_pass"
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :training_courses, :slug, unique: true

    create_table :training_lessons, id: :uuid do |t|
      t.references :training_course, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :title, null: false
      t.text :body
      t.string :video_url
      # Must the video be watched through, without seeking ahead, before the
      # lesson can be finished or its quiz opened?
      t.boolean :require_full_watch, null: false, default: true
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    create_table :training_questions, id: :uuid do |t|
      t.references :training_lesson, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.text :prompt, null: false
      t.text :explanation
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    create_table :training_question_options, id: :uuid do |t|
      t.references :training_question, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :body, null: false
      t.boolean :correct, null: false, default: false
      # Why this answer is right or wrong, shown when it's chosen.
      t.text :explanation
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    create_table :training_enrollments, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :training_course, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.timestamps
    end
    add_index :training_enrollments, [ :user_id, :training_course_id ], unique: true

    create_table :training_lesson_completions, id: :uuid do |t|
      t.references :training_enrollment, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :training_lesson, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :completed_at, null: false
      t.integer :score
      t.timestamps
    end
    add_index :training_lesson_completions, [ :training_enrollment_id, :training_lesson_id ], unique: true,
      name: "index_training_lesson_completions_on_enrollment_and_lesson"

    # How far into a lesson's video someone has genuinely watched. Progress
    # arrives from the player in heartbeats and is capped by the time that has
    # actually passed, so seeking ahead or replaying requests can't fake it.
    create_table :training_video_views, id: :uuid do |t|
      t.references :training_enrollment, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :training_lesson, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.float :watched_seconds, null: false, default: 0
      t.float :duration_seconds
      t.datetime :last_heartbeat_at
      t.datetime :completed_at
      t.timestamps
    end
    add_index :training_video_views, [ :training_enrollment_id, :training_lesson_id ], unique: true,
      name: "index_training_video_views_on_enrollment_and_lesson"

    # Every quiz submission, pass or fail, so there is a record of how someone
    # got through and not just that they did.
    create_table :training_quiz_attempts, id: :uuid do |t|
      t.references :training_enrollment, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :training_lesson, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.integer :score, null: false
      t.boolean :passed, null: false
      t.jsonb :responses, null: false, default: {}
      t.timestamps
    end

    # Awards are the durable record: they survive a course being edited,
    # archived, or retaken. A course award names its course; a manual one
    # names who granted it instead.
    create_table :training_badge_awards, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :training_badge, type: :uuid, null: false, foreign_key: true
      t.references :training_course, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :awarded_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :awarded_at, null: false
      t.datetime :expires_at
      t.text :note
      t.datetime :revoked_at
      t.references :revoked_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.text :revoked_reason
      t.timestamps
    end
    add_index :training_badge_awards, [ :user_id, :training_badge_id ]

    # People working an event who get no access to its data. They're on the
    # roster so their training can be tracked alongside staff.
    create_table :event_volunteers, id: :uuid do |t|
      t.references :event, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :added_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :event_volunteers, [ :event_id, :user_id ], unique: true
  end
end
