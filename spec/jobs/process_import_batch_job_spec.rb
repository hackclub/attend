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
end
