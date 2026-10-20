require "rails_helper"

RSpec.describe FetchTrainingVideoLengthJob do
  include ActiveJob::TestHelper

  let(:url) { "https://vimeo.com/123456" }

  it "is queued when a lesson's video link is saved" do
    lesson = create(:training_lesson)
    expect { lesson.update!(video_url: url) }
      .to have_enqueued_job(described_class).with(lesson.id, url)
  end

  it "isn't queued when the length is typed in with the link" do
    lesson = create(:training_lesson)
    expect { lesson.update!(video_url: url, video_duration_seconds: 90) }
      .not_to have_enqueued_job(described_class)
  end

  it "fills in the length it looks up" do
    lesson = create(:training_lesson, video_url: url)
    allow(TrainingVideoLength).to receive(:for).and_return(563.0)

    described_class.perform_now(lesson.id, url)
    expect(lesson.reload.video_duration_seconds).to eq(563.0)
  end

  it "skips a lesson whose link has changed since" do
    lesson = create(:training_lesson, video_url: "https://vimeo.com/999999")
    expect(TrainingVideoLength).not_to receive(:for)

    described_class.perform_now(lesson.id, url)
    expect(lesson.reload.video_duration_seconds).to be_nil
  end

  it "never overwrites a length set in the meantime" do
    lesson = create(:training_lesson, video_url: url)
    allow(TrainingVideoLength).to receive(:for) do
      TrainingLesson.where(id: lesson.id).update_all(video_duration_seconds: 120)
      563.0
    end

    described_class.perform_now(lesson.id, url)
    expect(lesson.reload.video_duration_seconds).to eq(120)
  end
end
