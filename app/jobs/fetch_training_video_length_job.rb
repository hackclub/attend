# Fills in a lesson's video length from YouTube or Vimeo after its link is
# saved (TrainingVideoLength). Skips quietly if the link changed again in the
# meantime, or the length was set by other means first.
class FetchTrainingVideoLengthJob < ApplicationJob
  queue_as :default

  def perform(lesson_id, video_url)
    lesson = TrainingLesson.find_by(id: lesson_id)
    return if lesson.nil? || lesson.video_url != video_url || lesson.known_video_duration

    seconds = TrainingVideoLength.for(lesson)
    return if seconds.nil?

    # Only fill a gap: an admin may have typed a length while this ran.
    TrainingLesson.where(id: lesson.id, video_url: video_url, video_duration_seconds: nil)
      .update_all(video_duration_seconds: seconds, updated_at: Time.current)
  end
end
