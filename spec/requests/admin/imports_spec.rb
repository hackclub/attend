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

  it "reads a Windows-1252 export with accented names, and asks for the names to be checked" do
    upload("Email,First Name,Last Name\njose@example.com,José,Müller\n".encode(Encoding::Windows_1252).b)

    expect(last_batch.rows_data.first).to include("legal_first_name" => "José", "legal_last_name" => "Müller")
    expect(response).to redirect_to(preview_admin_event_import_path(event.slug, last_batch, read_as: "windows-1252"))

    follow_redirect!
    expect(response.body).to include("read as Windows-1252")
  end

  it "reads Excel's tab-separated UTF-16 \"Unicode Text\"" do
    upload("\uFEFFEmail\tFirst Name\tLast Name\nzoe@example.com\tZoë\tExample\n".encode(Encoding::UTF_16LE).b)

    expect(last_batch.rows_data.first).to include("email" => "zoe@example.com", "legal_first_name" => "Zoë")
  end

  describe "a file that can't be read" do
    it "explains a malformed CSV instead of failing" do
      expect { upload("Email,First Name\n\"broken@example.com,Pat\n") }.not_to change(ImportBatch, :count)

      expect(response).to redirect_to(new_admin_event_import_path(event.slug))
      expect(flash[:alert]).to start_with("This file isn't a valid CSV: Unclosed quoted field")
    end

    context "in the console" do
      let(:console) { true }

      it "shows bytes that aren't text in any encoding it knows under the file field" do
        upload("Email,First Name\nx@example.com,\x81\x8D\n".b)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("Save it from your spreadsheet as &quot;CSV UTF-8&quot;")
      end
    end
  end

  [ false, true ].each do |console_variant|
    context "previewing rows the job would reject (console=#{console_variant})" do
      let(:console) { console_variant }

      before do
        create(:participant, email: "returning@example.com")
        create(:participant_event, participant: create(:participant, email: "registered@example.com"), event: event)

        upload("Email,Last Name\n" \
               "returning@example.com,\n" \
               "registered@example.com,Here\n" \
               "not-an-email,Nobody\n" \
               "new@example.com,Newcomer\n" \
               "returning@example.com,Again\n")
        follow_redirect!
      end

      it "fails them with the reason, and counts only the rows that will import" do
        expect(response.body).to include("The file has no First Name column", "Won't be imported")
        expect(response.body).to include("Already registered", "Invalid email address", "Missing first name", "Same email as row 2")
        expect(response.body).to include(console_variant ? "cs-status-error" : "text-red-700")
        expect(response.body).not_to include("read as Windows-1252")

        valid_rows = controller.instance_variable_get(:@valid_rows)
        expect(valid_rows.pluck(:email)).to eq([ "returning@example.com" ])
      end
    end
  end

  it "previews the rejections the job's other validations would make" do
    create(:ban, email: "banned@example.com")
    create(:guardian, email: "known-parent@example.com")

    upload("Email,First Name,Last Name,Birthday,Parent Email,Parent First Name,Parent Last Name,Emergency Contact First Name,Emergency Contact Phone\n" \
           "banned@example.com,Ban,Ned,,,,,,\n" \
           "adult@example.com,Ad,Ult,1/2/1990,,,,,\n" \
           "noparent@example.com,No,Parent,,mum@example.com,,,,\n" \
           "badparent@example.com,Bad,Parent,,not-an-email,,,,\n" \
           "badphone@example.com,Bad,Phone,,,,,Em,not a phone\n" \
           "known@example.com,Known,Parent,,known-parent@example.com,,,Em,+14155550132\n" \
           "self@example.com,Self,Parent,,SELF@example.com,,,,\n")
    follow_redirect!

    skipped = controller.instance_variable_get(:@skipped_rows).to_h { |row| [ row[:email], row[:reason] ] }
    expect(skipped).to eq(
      "banned@example.com" => "Banned from events",
      "adult@example.com" => "19 or older during this event",
      "noparent@example.com" => "Missing parent first name and parent last name",
      "badparent@example.com" => "Invalid parent email",
      "badphone@example.com" => "Invalid emergency contact phone"
    )
    expect(controller.instance_variable_get(:@valid_rows).pluck(:email)).to eq([ "known@example.com", "self@example.com" ])
  end
end
