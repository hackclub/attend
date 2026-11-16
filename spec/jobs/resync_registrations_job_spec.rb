require "rails_helper"

RSpec.describe ResyncRegistrationsJob do
  let(:event) { create(:event, travel_enabled: false, freedom_waivers_enabled: false) }

  def complete_adult
    participant = create(:participant, date_of_birth: 18.years.ago - 1.month)
    complete_registration(create(:participant_event, participant: participant, event: event))
  end

  it "carries on past a registration that can't be saved, and reports it" do
    broken = complete_adult
    healthy = [ complete_adult, complete_adult ]
    event.update_columns(config: event.config.merge("travel_enabled" => true))

    allow_any_instance_of(ParticipantEvent).to receive(:sync_status!).and_wrap_original do |original, **options|
      raise ActiveRecord::RecordInvalid, original.receiver if original.receiver.id == broken.id

      original.call(**options)
    end
    expect(Rails.error).to receive(:report)
      .with(an_instance_of(ActiveRecord::RecordInvalid), hash_including(handled: true)).once

    described_class.perform_now(event.id)

    expect(healthy.map { |participant_event| participant_event.reload.status }).to all(eq("in_progress"))
    expect(broken.reload).to be_complete
  end
end
