# A hand-made invitation to an invite-only course (TrainingCourse#access).
# People whose event role needs the course's badge don't need one — see
# TrainingAccess.
class TrainingCourseInvitation < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :course, class_name: "TrainingCourse", foreign_key: :training_course_id
  belongs_to :user
  belongs_to :invited_by, class_name: "User", optional: true

  validates :user_id, uniqueness: { scope: :training_course_id, message: "is already invited to this course" }
end
