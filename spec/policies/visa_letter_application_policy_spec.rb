require "rails_helper"

RSpec.describe VisaLetterApplicationPolicy do
  let(:event) { create(:event) }
  let(:application) { create(:visa_letter_application, event: event) }

  after { Current.reset }

  def staff(role)
    create(:user).tap { |user| create(:event_role_assignment, user: user, event: event, role: role) }
  end

  it "lets the event's admins and global admins review" do
    [ staff("event_admin"), create(:user, global_role: "global_admin") ].each do |user|
      policy = described_class.new(user, application)
      expect(policy.review?).to be(true)
      expect(policy.show?).to be(true)
    end
  end

  it "keeps ops, limited, safeguarding and read-only staff out of applicants' details" do
    %w[ops limited safeguarding_lead read_only].each do |role|
      user = staff(role)
      expect(described_class.new(user, application).show?).to be(false), "#{role} could see an application"
      Current.event = event
      expect(described_class::Scope.new(user, VisaLetterApplication).resolve).to be_empty
      Current.reset
    end
  end

  it "shows applicants their own applications only" do
    other = create(:visa_letter_application, event: event)

    expect(described_class.new(application.user, application).show?).to be(true)
    expect(described_class.new(application.user, application).review?).to be(false)
    expect(described_class.new(application.user, other).show?).to be(false)
    expect(described_class::Scope.new(application.user, VisaLetterApplication).resolve).to contain_exactly(application)
  end

  it "scopes reviewers to the current event" do
    admin = staff("event_admin")
    elsewhere = create(:visa_letter_application)
    Current.event = event

    expect(described_class::Scope.new(admin, VisaLetterApplication).resolve).to contain_exactly(application)
    expect(described_class::Scope.new(admin, VisaLetterApplication).resolve).not_to include(elsewhere)
  end
end
