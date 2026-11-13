require "rails_helper"

RSpec.describe TrainingFunnel do
  let(:course) { create(:training_course) }
  let!(:video) { create(:training_lesson, course: course, title: "Video", video_url: "https://youtu.be/abcdefghijk", video_duration_seconds: 60) }
  let!(:reading) { create(:training_lesson, course: course, title: "Reading") }
  let!(:last) { create(:training_lesson, course: course, title: "Last", video_url: "https://youtu.be/kjihgfedcba", video_duration_seconds: 60) }

  def enroll(opened: [], watched: [], completed: [], finished: false)
    enrollment = create(:training_enrollment, course: course, completed_at: (Time.current if finished))
    (opened | watched).each do |lesson|
      enrollment.video_views.create!(lesson: lesson, completed_at: (Time.current if watched.include?(lesson)))
    end
    completed.each { |lesson| enrollment.lesson_completions.create!(lesson: lesson, completed_at: Time.current) }
    enrollment
  end

  it "counts each lesson's opens, full watches, completions and who stopped there" do
    enroll
    enroll(opened: [ video ])
    enroll(watched: [ video ], completed: [ video ])
    enroll(watched: [ video ], completed: [ video, reading ], opened: [ last ])
    enroll(watched: [ video, last ], completed: [ video, reading, last ], finished: true)
    create(:training_enrollment, course: create(:training_course)) # another course

    funnel = described_class.new(course.reload)
    steps = funnel.steps.index_by { |step| step.lesson.title }

    expect([ funnel.started, funnel.finished ]).to eq [ 5, 1 ]
    expect(steps["Video"].to_h.except(:lesson)).to eq(opened: 4, watched: 3, completed: 3, stopped: 2)
    expect(steps["Reading"].to_h.except(:lesson)).to eq(opened: nil, watched: nil, completed: 2, stopped: 1)
    expect(steps["Last"].to_h.except(:lesson)).to eq(opened: 2, watched: 1, completed: 1, stopped: 1)
    expect(funnel.percent_of_started(3)).to eq 60
  end

  it "places a learner on the first lesson they haven't done, whatever order they did them in" do
    enroll(completed: [ video, last ])

    steps = described_class.new(course.reload).steps.index_by { |step| step.lesson.title }

    expect(steps.transform_values(&:stopped)).to eq("Video" => 0, "Reading" => 1, "Last" => 0)
  end
end
