require "rails_helper"

RSpec.describe IncidentsToolbox do
  let(:event) { create(:event) }
  let(:admin) { create(:user, global_role: "global_admin") }
  let(:incident) { create(:incident, event: event, reported_by: admin) }

  def run(action, params = {}, actor:)
    toolbox = described_class.new(params: params.transform_keys(&:to_s))
    allow(toolbox).to receive(:current_user).and_return(actor)
    allow(toolbox).to receive(:current_event).and_return(event) if toolbox.respond_to?(:current_event, true)
    catch(:halt) { toolbox.public_send(action) }
    toolbox
  end

  def payload(toolbox) = JSON.parse(toolbox.instance_variable_get(:@_response)[:content].first[:text], symbolize_names: true)

  it "adds a comment and lists it back" do
    toolbox = run(:add_comment, { incident_id: incident.id, body: "Spoke to both attendees." }, actor: admin)
    expect(payload(toolbox)[:comments].map { |c| c[:body] }).to include("Spoke to both attendees.")
    expect(incident.comments.count).to eq(1)
  end
end
