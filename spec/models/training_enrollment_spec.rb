require "rails_helper"

RSpec.describe TrainingEnrollment do
  let(:course) { create(:training_course, :published) }
  let(:enrollment) { create(:training_enrollment, course: course) }
  let(:reading) { course.lessons.first }
  let(:quiz) { course.lessons.second }

  it "opens lessons in order" do
    expect(enrollment.lesson_unlocked?(reading)).to be(true)
    expect(enrollment.lesson_unlocked?(quiz)).to be(false)

    enrollment.complete_lesson!(reading)
    expect(enrollment.lesson_unlocked?(quiz)).to be(true)
  end

  it "awards the course badge, with its validity, once every lesson is done" do
    enrollment.complete_lesson!(reading)
    award = nil
    expect { award = enrollment.complete_lesson!(quiz, score: 100) }.to change(TrainingBadgeAward, :count).by(1)

    expect(enrollment.reload).to be_completed
    expect(award.badge).to eq(course.badge)
    expect(award.expires_at).to be_within(1.minute).of(12.months.from_now)
  end

  it "awards nothing for a draft course an admin walks through" do
    course.update!(status: "draft")
    enrollment.complete_lesson!(reading)
    expect { enrollment.complete_lesson!(quiz, score: 100) }.not_to change(TrainingBadgeAward, :count)
  end

  it "restarts from scratch without touching awards" do
    enrollment.complete_lesson!(reading)
    enrollment.complete_lesson!(quiz, score: 100)

    expect { enrollment.restart! }.not_to change(TrainingBadgeAward, :count)
    expect(enrollment.reload).not_to be_completed
    expect(enrollment.lesson_completions).to be_empty
  end

  describe "the video gate" do
    before { reading.update!(video_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") }

    it "stays shut until the video is watched through" do
      expect(enrollment.video_watched?(reading)).to be(false)

      view = enrollment.video_view_for(reading)
      view.update!(duration_seconds: 60, watched_seconds: 59, completed_at: Time.current)
      expect(enrollment.video_watched?(reading)).to be(true)
    end

    it "is open when watching isn't required" do
      reading.update!(require_full_watch: false)
      expect(enrollment.video_watched?(reading)).to be(true)
    end
  end
end
