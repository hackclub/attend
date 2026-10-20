# How much of a lesson's video someone has really watched. The player sends
# its position every few seconds; each heartbeat may only move the watched
# mark forward by the time that has actually passed since the last one (or
# since the lesson page loaded), times MAX_PLAYBACK_RATE. There is no
# per-heartbeat allowance on top: one would compound, since the player
# reports on every pause and a scrub fires several. So seeking ahead, or
# posting made-up positions, can't finish a video early.
class TrainingVideoView < ApplicationRecord
  self.implicit_order_column = "created_at"

  MAX_PLAYBACK_RATE = 2.0
  # Close enough to the end to count as watched: the last frame often never
  # fires a timeupdate.
  END_TOLERANCE_SECONDS = 1.0

  belongs_to :enrollment, class_name: "TrainingEnrollment", foreign_key: :training_enrollment_id
  belongs_to :lesson, class_name: "TrainingLesson", foreign_key: :training_lesson_id

  def completed?
    completed_at.present?
  end

  def record_heartbeat!(position:, duration:, now: Time.current)
    with_lock do
      # The first duration reported sticks, so it can't be shortened later
      # to finish sooner. An analysed upload's real length beats either.
      self.duration_seconds = lesson.known_video_duration || duration_seconds || positive(duration)

      # The row is created when the lesson page loads (LessonsController#show),
      # so the first heartbeat is measured from then.
      elapsed = [ now - (last_heartbeat_at || created_at), 0 ].max
      allowed = watched_seconds + (elapsed * MAX_PLAYBACK_RATE)
      reached = [ positive(position) || 0, allowed ].min
      reached = [ reached, duration_seconds ].min if duration_seconds
      self.watched_seconds = [ watched_seconds, reached ].max
      self.last_heartbeat_at = now
      self.completed_at ||= now if finished?
      save!
    end
    self
  end

  def finished?
    duration_seconds.present? && watched_seconds >= duration_seconds - END_TOLERANCE_SECONDS
  end

  private

  def positive(value)
    number = Float(value, exception: false)
    number if number&.finite? && number.positive?
  end
end
