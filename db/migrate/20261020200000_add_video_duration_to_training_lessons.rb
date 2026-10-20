class AddVideoDurationToTrainingLessons < ActiveRecord::Migration[8.1]
  def change
    # The video's real length, from an admin's preview or typed in, so a
    # learner's player can't claim a shorter one (TrainingVideoView).
    add_column :training_lessons, :video_duration_seconds, :float
  end
end
