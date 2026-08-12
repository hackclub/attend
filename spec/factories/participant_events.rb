FactoryBot.define do
  factory :participant_event do
    participant
    event
    status { :in_progress }
    onboarding_step { 0 }

    # Check-in is a Scan in a checks_in ScanContext, so "checked in" means
    # exactly that. Override `check_in_time` for a specific time.
    trait :checked_in do
      transient do
        check_in_time { Time.current }
      end

      after(:create) do |pe, evaluator|
        # Events get a checks_in context on create; tolerate one that doesn't.
        context = pe.event.scan_contexts.find_by(checks_in: true) ||
                  pe.event.scan_contexts.create!(name: "Check-in", checks_in: true)
        pe.scans.create!(
          scan_context: context,
          user: FactoryBot.create(:user),
          scanned_at: evaluator.check_in_time
        )
      end
    end
  end
end
