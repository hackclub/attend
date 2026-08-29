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
end
