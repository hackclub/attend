class TrainingLesson < ApplicationRecord
  include TrainingPositioned

  self.implicit_order_column = "created_at"

  has_paper_trail

  # Links a lesson video may come from. Only players whose position can be
  # read and corrected from the page are accepted, so "no skipping" can be
  # enforced (training_video_controller.js). Each captures the video ID.
  VIDEO_LINKS = {
    youtube: %r{\Ahttps://(?:www\.|m\.)?(?:youtube\.com/watch\?(?:.*&)?v=|youtu\.be/|youtube\.com/embed/|youtube-nocookie\.com/embed/)([\w-]{6,})},
    vimeo: %r{\Ahttps://(?:www\.|player\.)?vimeo\.com/(?:video/)?(\d+)}
  }.freeze

  VIDEO_CONTENT_TYPES = %w[video/mp4 video/webm video/quicktime].freeze
  MAX_VIDEO_SIZE = 1.gigabyte

  belongs_to :course, class_name: "TrainingCourse", foreign_key: :training_course_id, inverse_of: :lessons, touch: true
  has_many :questions, -> { ordered }, class_name: "TrainingQuestion", dependent: :destroy, inverse_of: :lesson
  has_many :completions, class_name: "TrainingLessonCompletion", dependent: :destroy
  has_many :quiz_attempts, class_name: "TrainingQuizAttempt", dependent: :destroy
  has_many :video_views, class_name: "TrainingVideoView", dependent: :destroy

  # An uploaded video plays in Attend's own player, which gives the tightest
  # control over seeking; a YouTube or Vimeo link is the alternative.
  has_one_attached :video_file

  validates :title, presence: true
  validate :video_url_embeddable, if: -> { video_url.present? }
  validate :acceptable_video_file, if: -> { video_file.attached? }
  validate :one_video_source

  normalizes :video_url, with: ->(url) { url.strip.presence }

  def quiz?
    questions.any?
  end

  # :upload, :youtube, :vimeo, or nil when the lesson has no video.
  def video_source
    return :upload if video_file.attached?

    VIDEO_LINKS.each_key { |source| return source if video_id_for(source) }
    nil
  end

  def video?
    video_source.present?
  end

  def video_id
    video_id_for(video_source) if video_source && video_source != :upload
  end

  # Whether the video must be watched through before the lesson can be
  # finished or its quiz opened.
  def watch_required?
    video? && require_full_watch?
  end

  # Length of an uploaded video when Active Storage could analyse it (needs
  # ffprobe on the host); nil otherwise, and the player reports it instead.
  def known_video_duration
    return unless video_source == :upload

    duration = video_file.blob.metadata["duration"]
    duration.to_f if duration.to_f.positive?
  end

  private

  def siblings
    TrainingLesson.where(training_course_id: training_course_id)
  end

  def video_id_for(source)
    video_url.to_s.match(VIDEO_LINKS.fetch(source))&.[](1)
  end

  def video_url_embeddable
    errors.add(:video_url, "must be a YouTube or Vimeo link") unless VIDEO_LINKS.each_key.any? { |source| video_id_for(source) }
  end

  def acceptable_video_file
    unless video_file.blob.content_type.in?(VIDEO_CONTENT_TYPES)
      errors.add(:video_file, "must be an MP4, WebM, or MOV file")
    end
    if video_file.blob.byte_size > MAX_VIDEO_SIZE
      errors.add(:video_file, "must be smaller than 1 GB — for anything longer, use an unlisted YouTube or Vimeo link")
    end
  end

  def one_video_source
    return unless video_file.attached? && video_url.present?

    errors.add(:video_url, "can't be set as well as an uploaded video — remove one")
  end
end
