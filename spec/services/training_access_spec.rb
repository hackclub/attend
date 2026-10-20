require "rails_helper"

RSpec.describe TrainingAccess do
  let(:user) { create(:user) }
  let(:badge) { create(:training_badge, required_roles: %w[safeguarding_lead]) }
  let!(:course) { create(:training_course, :published, badge: badge) }
  let(:upcoming) { create(:event, starts_at: 1.week.from_now, ends_at: 8.days.from_now) }

  def access = TrainingAccess.new(user)

  it "gives no access without an invitation or a matching event role" do
    create(:event_role_assignment, event: upcoming, user: user, role: "ops")
    expect(access.reason(course)).to be_nil
    expect(access.courses).to be_empty
  end

  it "counts a hand-made invitation" do
    TrainingCourseInvitation.create!(course: course, user: user)
    expect(access.reason(course)).to eq(:invited)
    expect(access.courses).to eq([ course ])
  end

  it "counts a role at an upcoming event that needs the badge" do
    create(:event_role_assignment, event: upcoming, user: user, role: "safeguarding_lead")
    expect(access.reason(course)).to eq(:event)
    expect(access.events_for(course)).to eq([ upcoming ])
  end

  it "counts open courses, and lets global admins see everything" do
    course.update!(access: "open")
    expect(access.reason(course)).to eq(:open)

    course.update!(access: "invite_only")
    user.update!(global_role: "global_admin")
    expect(access.reason(course)).to eq(:admin)
  end
end
