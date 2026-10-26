require "rails_helper"

RSpec.describe "Admin safety reviews", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, global_role: "global_admin") }
  let(:person) { create(:user, email: "declared-example@example.com") }
  let(:course) { create(:training_course) }
  let!(:disclosure) { person.training_disclosures.create!(course: course, question: "Example declaration?", answer: "yes") }

  before { sign_in admin }

  [ true, false ].each do |console|
    it "lists and shows declarations, logging each view (#{console ? "console" : "original"})" do
      admin.update!(admin_console_beta: console)
      get admin_training_disclosures_path
      expect(response.body).to include("declared-example@example.com")

      expect {
        get admin_training_disclosure_path(disclosure)
      }.to change { AuditLog.where(record: disclosure, action: "view").count }.by(1)
      expect(response.body).to include("Example declaration?")
    end
  end

  it "clears someone with a note" do
    patch admin_training_disclosure_path(disclosure), params: { outcome: "cleared", note: "Example review note." }
    expect(disclosure.reload).to be_review_cleared
    expect(disclosure.reviewed_by).to eq(admin)
    expect(person).to be_eligible_to_work_events
  end

  it "won't review without a note" do
    patch admin_training_disclosure_path(disclosure), params: { outcome: "upheld", note: "" }
    expect(disclosure.reload).to be_review_pending
  end

  it "flags pending reviews on the training overview" do
    get admin_training_path
    expect(response.body).to include("1 declaration")
  end

  it "is closed to anyone but global admins" do
    event = create(:event)
    staff = create(:event_role_assignment, event: event, role: "event_admin").user
    sign_in staff

    get admin_training_disclosure_path(disclosure)
    expect(response).to redirect_to(admin_root_path)
  end
end
