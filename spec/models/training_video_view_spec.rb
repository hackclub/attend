require "rails_helper"

RSpec.describe TrainingVideoView do
  include ActiveSupport::Testing::TimeHelpers

  let(:lesson) { create(:training_lesson, video_url: "https://vimeo.com/123456", video_duration_seconds: 600) }
  let(:enrollment) { create(:training_enrollment, course: lesson.course) }
  let(:start) { Time.zone.local(2026, 10, 1, 12) }
  # Created when the lesson page loads, which starts the watch clock.
  let(:view) { travel_to(start) { enrollment.video_view_for(lesson) } }

  it "won't credit a jump to the end" do
    view.record_heartbeat!(position: 590, now: start + 1)
    expect(view.watched_seconds).to eq(2)
    expect(view).not_to be_completed
  end

  it "credits no more than real time allows, at up to 2x" do
    view.record_heartbeat!(position: 0, now: start)
    view.record_heartbeat!(position: 400, now: start + 60)
    expect(view.watched_seconds).to eq(120)
  end

  # Regression: an allowance added per heartbeat compounded, and the player
  # reports on every pause, so a few quick scrubs finished a 12s clip in 3s.
  it "gives nothing extra for frequent heartbeats" do
    lesson.update!(video_duration_seconds: 12)
    10.times { |i| view.record_heartbeat!(position: 12, now: start + (i * 0.3)) }
    expect(view.watched_seconds).to be <= (2 * 2.7) + 0.01
    expect(view).not_to be_completed
  end

  it "completes once the end is reached in real time" do
    (1..60).each { |i| view.record_heartbeat!(position: i * 10, now: start + (i * 10)) }
    expect(view).to be_completed
  end

  it "never moves backwards" do
    view.record_heartbeat!(position: 20, now: start + 20)
    view.record_heartbeat!(position: 3, now: start + 25)
    expect(view.watched_seconds).to eq(20)
  end

  # Fail closed: a learner's player is never trusted for the length, so a
  # video whose length Attend doesn't know can't be finished at all.
  it "can't complete while the lesson's length is unknown" do
    lesson.update!(video_duration_seconds: nil)
    (1..60).each { |i| view.record_heartbeat!(position: i * 10, now: start + (i * 10)) }
    expect(view.duration_seconds).to be_nil
    expect(view).not_to be_completed
  end

  describe "the lesson's length" do
    it "is learned from an admin's preview only once, and forgotten when the video changes" do
      lesson.update!(video_duration_seconds: nil)
      lesson.learn_video_duration!(600)
      lesson.learn_video_duration!(5)
      expect(lesson.reload.video_duration_seconds).to eq(600)

      lesson.update!(video_url: "https://vimeo.com/654321")
      expect(lesson.reload.video_duration_seconds).to be_nil
    end

    it "is forgotten when an uploaded video is replaced" do
      upload = ->(name) { { io: StringIO.new("not really a video"), filename: name, content_type: "video/mp4" } }
      lesson.update!(video_url: nil)
      lesson.video_file.attach(upload.call("first.mp4"))
      lesson.update!(video_duration_seconds: 600)

      lesson.update!(video_file: upload.call("second.mp4"))
      expect(lesson.reload.video_duration_seconds).to be_nil
    end

    it "blocks publishing a course until every must-watch video's length is known" do
      course = create(:training_course, :with_lessons)
      course.lessons.first.update!(video_url: "https://vimeo.com/123456")
      expect(course.reload.update(status: "published")).to be(false)
      expect(course.errors[:status].join).to include("play it once in the preview")

      course.lessons.first.update!(video_duration_seconds: 90)
      expect(course.reload.update(status: "published")).to be(true)
    end
  end
end
