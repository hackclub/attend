require "rails_helper"

RSpec.describe MedicalToolbox do
  # Tool actions need an OAuth-authenticated Toolchest dispatch, so this drives
  # the toolbox directly with current_user stubbed.
  let(:user) { create(:user) }
  let(:participant_event) { create(:participant_event) }

  # Other toolbox specs leave Current.user pointing at a rolled-back user.
  before { Current.reset }
  after { Current.reset }

  it "flags anaphylaxis risk over a saved nothing to add" do
    participant_event.create_medical!(section_response: :nothing_to_add)

    toolbox = described_class.new(params: {
      "participant_event_id" => participant_event.id, "has_anaphylaxis_risk" => true
    })
    allow(toolbox).to receive(:current_user).and_return(user)
    allow(toolbox).to receive(:authorize!).and_return(true)
    allow(toolbox).to receive(:render)
    toolbox.update

    expect(participant_event.medical.reload).to have_attributes(has_anaphylaxis_risk: true, section_response: "details")
  end
end
