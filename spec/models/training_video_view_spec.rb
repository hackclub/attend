require "rails_helper"

RSpec.describe TrainingVideoView do
  include ActiveSupport::Testing::TimeHelpers

  let(:lesson) { create(:training_lesson, video_url: "https://vimeo.com/123456") }
  let(:enrollment) { create(:training_enrollment, course: lesson.course) }
  let(:start) { Time.zone.local(2026, 10, 1, 12) }
  # Created when the lesson page loads, which starts the watch clock.
  let(:view) { travel_to(start) { enrollment.video_view_for(lesson) } }

  it "won't credit a jump to the end" do
    view.record_heartbeat!(position: 590, duration: 600, now: start + 1)
    expect(view.watched_seconds).to eq(2)
    expect(view).not_to be_completed
  end

  it "credits no more than real time allows, at up to 2x" do
    view.record_heartbeat!(position: 0, duration: 600, now: start)
    view.record_heartbeat!(position: 400, duration: 600, now: start + 60)
    expect(view.watched_seconds).to eq(120)
  end

  # Regression: an allowance added per heartbeat compounded, and the player
  # reports on every pause, so a few quick scrubs finished a 12s clip in 3s.
  it "gives nothing extra for frequent heartbeats" do
    10.times { |i| view.record_heartbeat!(position: 12, duration: 12, now: start + (i * 0.3)) }
    expect(view.watched_seconds).to be <= (2 * 2.7) + 0.01
    expect(view).not_to be_completed
  end

  it "completes once the end is reached in real time" do
    (1..60).each { |i| view.record_heartbeat!(position: i * 10, duration: 600, now: start + (i * 10)) }
    expect(view).to be_completed
  end

  it "keeps the first duration, so it can't be shortened later" do
    view.record_heartbeat!(position: 0, duration: 600, now: start)
    view.record_heartbeat!(position: 5, duration: 5, now: start + 5)
    expect(view.duration_seconds).to eq(600)
    expect(view).not_to be_completed
  end

  it "never moves backwards" do
    view.record_heartbeat!(position: 20, duration: 600, now: start + 20)
    view.record_heartbeat!(position: 3, duration: 600, now: start + 25)
    expect(view.watched_seconds).to eq(20)
  end
end
