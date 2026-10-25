FactoryBot.define do
  factory :training_badge do
    sequence(:name) { |n| "Example Safety Badge #{n}" }
    validity_months { 12 }
    required_roles { [] }
  end

  factory :training_course do
    sequence(:title) { |n| "Example Course #{n}" }
    badge factory: :training_badge
    pass_mark { 80 }

    # A reading, then a lesson with one single-answer question.
    trait :with_lessons do
      after(:create) do |course|
        create(:training_lesson, course: course, title: "Reading")
        quiz = create(:training_lesson, course: course, title: "Quiz")
        create(:training_question, lesson: quiz)
        course.lessons.reset
      end
    end

    trait :published do
      with_lessons
      after(:create) { |course| course.update!(status: "published") }
    end
  end

  factory :training_lesson do
    course factory: :training_course
    sequence(:title) { |n| "Lesson #{n}" }
    body { "## Heading\n\nSome **important** text." }
  end

  factory :training_question do
    lesson factory: :training_lesson
    prompt { "Which answer is right?" }
    explanation { "Because it is." }

    after(:build) do |question|
      if question.options.empty?
        question.options.build(body: "The right one", correct: true, explanation: "Yes — this is why.")
        question.options.build(body: "The wrong one", correct: false, explanation: "No — this is why not.")
      end
    end
  end

  factory :training_enrollment do
    user
    course factory: :training_course
  end

  factory :training_badge_award do
    user
    badge factory: :training_badge
    awarded_at { Time.current }
    expires_at { 1.year.from_now }
  end

  factory :event_volunteer do
    event
    user
  end
end
