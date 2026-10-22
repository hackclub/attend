require "rails_helper"

# The CSV import as organizers use it: ordinary spreadsheet exports, not only
# the template, and a preview that agrees with what the job will do. Issue #167.
RSpec.describe "Admin CSV import", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:event) { create(:event) }
  let(:console) { false }
  let(:admin) { User.create!(email: "ga-imports@example.com", name: "Global Admin", global_role: "global_admin", admin_console_beta: console) }

  before { sign_in admin }

  def upload(content, filename: "participants.csv")
    post admin_event_imports_path(event.slug), params: {
      csv_file: Rack::Test::UploadedFile.new(StringIO.new(content), "text/csv", original_filename: filename),
      send_invitations: "0"
    }
  end

  def last_batch
    event.import_batches.order(:created_at).last
  end

  it "matches headers ignoring case, spacing and common aliases, then imports what the preview promised" do
    upload(" EMAIL address ,first  name,LAST NAME,groups\n" \
           "Ada@Example.com,Ada,Lovelace,\n" \
           "nofirst@example.com,,Hopper,\n")

    expect(response).to redirect_to(preview_admin_event_import_path(event.slug, last_batch))
    expect(last_batch.rows_data.first).to include("email" => "Ada@Example.com", "legal_first_name" => "Ada", "legal_last_name" => "Lovelace")

    follow_redirect!
    expect(response.body).to include("ada@example.com", "Missing first name")
    expect(response.body).not_to include("The file has no")

    perform_enqueued_jobs(only: ProcessImportBatchJob) do
      post confirm_admin_event_import_path(event.slug, last_batch)
    end

    batch = last_batch.reload
    expect(batch).to be_completed
    expect([ batch.imported_count, batch.error_count ]).to eq([ 1, 1 ])
    expect(event.participants.pluck(:email)).to eq([ "ada@example.com" ])
  end

  it "keeps the first value when two headers name the same field" do
    upload("Email,Email Address,First Name,Last Name\nfirst@example.com,second@example.com,Pat,Example\n" \
           ",only@example.com,Sam,Example\n")

    expect(last_batch.rows_data.pluck("email")).to eq([ "first@example.com", "only@example.com" ])
  end

  it "strips a byte order mark" do
    upload("\xEF\xBB\xBFEmail,First Name,Last Name\nbom@example.com,Bo,Mark\n")

    expect(last_batch.rows_data).to eq([ { "email" => "bom@example.com", "legal_first_name" => "Bo", "legal_last_name" => "Mark" } ])
  end

  it "reads a Windows-1252 export with accented names" do
    upload("Email,First Name,Last Name\njose@example.com,José,Müller\n".encode(Encoding::Windows_1252).b)

    expect(last_batch.rows_data.first).to include("legal_first_name" => "José", "legal_last_name" => "Müller")
  end

  describe "a file that can't be read" do
    it "explains a malformed CSV instead of failing" do
      expect { upload("Email,First Name\n\"broken@example.com,Pat\n") }.not_to change(ImportBatch, :count)

      expect(response).to redirect_to(new_admin_event_import_path(event.slug))
      expect(flash[:alert]).to start_with("This file isn't a valid CSV: Unclosed quoted field")
    end

    it "explains bytes that aren't text in any encoding it knows" do
      expect { upload("Email,First Name\nx@example.com,\x81\x8D\n".b) }.not_to change(ImportBatch, :count)

      expect(flash[:alert]).to include("Save it from your spreadsheet as \"CSV UTF-8\"")
    end

    context "in the console" do
      let(:console) { true }

      it "shows the problem under the file field" do
        upload("Email,First Name\n\"broken@example.com,Pat\n")

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("This file isn&#39;t a valid CSV: Unclosed quoted field")
      end
    end
  end

  [ false, true ].each do |console_variant|
    context "previewing rows the job would reject (console=#{console_variant})" do
      let(:console) { console_variant }

      before do
        returning = create(:participant, email: "returning@example.com")
        create(:participant_event, participant: create(:participant, email: "registered@example.com"), event: event)

        upload("Email,Last Name\n" \
               "#{returning.email},\n" \
               "registered@example.com,Here\n" \
               "not-an-email,Nobody\n" \
               "new@example.com,Newcomer\n" \
               "returning@example.com,Again\n")
        follow_redirect!
      end

      it "fails them with the reason, and counts only the rows that will import" do
        expect(response.body).to include("The file has no First Name column")
        expect(response.body).to include("Already registered", "Invalid email address", "Missing first name", "Same email as row 2")
        expect(response.body).to include(console_variant ? "cs-status-error" : "text-red-700")

        valid_rows = controller.instance_variable_get(:@valid_rows)
        expect(valid_rows.pluck(:email)).to eq([ "returning@example.com" ])
      end
    end
  end
end
