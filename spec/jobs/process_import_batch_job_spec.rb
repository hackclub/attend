require "rails_helper"

RSpec.describe ProcessImportBatchJob do
  let(:event) { create(:event) }

  it "scrubs imported CSV rows after the batch completes" do
    import_batch = ImportBatch.create!(
      event: event,
      status: :pending,
      total_count: 1,
      send_invitations: false,
      rows_data: [
        {
          email: "participant@example.com",
          legal_first_name: "Pat",
          legal_last_name: "Example",
          phone: "+14155550123",
          date_of_birth: "1/15/08",
          address_line_1: "123 Main St"
        }
      ]
    )

    described_class.perform_now(import_batch.id)

    expect(import_batch.reload).to be_completed
    expect(import_batch.rows_data).to eq([])
  end

  it "imports a row whose parent email repeats the participant's, without a guardian" do
    import_batch = ImportBatch.create!(
      event: event,
      status: :pending,
      total_count: 1,
      send_invitations: false,
      rows_data: [
        {
          email: "solo@example.com",
          legal_first_name: "Pat",
          legal_last_name: "Example",
          parent_first_name: "Pat",
          parent_last_name: "Example",
          parent_email: "SOLO@example.com"
        }
      ]
    )

    expect { described_class.perform_now(import_batch.id) }.not_to change(Guardian, :count)

    import_batch.reload
    expect(import_batch.imported_count).to eq(1)
    expect(import_batch.errors_data.map { |e| e["error"] })
      .to include(a_string_matching(/Parent email is the same as the participant's email/))
  end

  describe "the Groups column" do
    def import_with_groups(groups)
      import_batch = ImportBatch.create!(
        event: event, status: :pending, total_count: 1, send_invitations: false,
        rows_data: [ { email: "grouped@example.com", legal_first_name: "Pat", legal_last_name: "Example", groups: groups } ]
      )
      described_class.perform_now(import_batch.id)
      ParticipantEvent.find_by!(event: event, participant: Participant.find_by!(email: "grouped@example.com"))
    end

    it "adds the participant to existing groups by name or slug, and creates new ones" do
      event.update!(groups_enabled: true)
      red = event.groups.create!(name: "Red Team")

      participant_event = import_with_groups("red team; red-team, Blue Team,")

      expect(participant_event.groups.pluck(:name)).to contain_exactly("Red Team", "Blue Team")
      expect(red.group_memberships.count).to eq(1)
    end

    it "matches a spelling that makes an existing group's slug, and adds new groups last" do
      event.update!(groups_enabled: true)
      red = event.groups.create!(name: "Red Team", position: 3)

      participant_event = import_with_groups("Red\u00A0 team!, Green Team")

      expect(participant_event.groups).to contain_exactly(red, event.groups.find_by!(name: "Green Team"))
      expect(event.groups.find_by!(name: "Green Team").position).to eq(4)
    end

    it "skips a name that can't be a group and still imports the participant" do
      event.update!(groups_enabled: true)

      participant_event = import_with_groups("!!!; Blue")

      expect(participant_event.groups.pluck(:name)).to eq([ "Blue" ])
      expect(ImportBatch.last.errors_data.pluck("error")).to include(a_string_starting_with('Group "!!!" not added: Slug'))
    end

    it "ignores the column when the event doesn't use groups" do
      participant_event = import_with_groups("Red Team")

      expect(participant_event.groups).to be_empty
      expect(event.groups).to be_empty
    end
  end
end
