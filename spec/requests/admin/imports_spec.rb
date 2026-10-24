require "rails_helper"

# The CSV import as organizers use it: ordinary spreadsheet exports, not only
# the template, and a preview that agrees with what the job will do. Issue #167.
RSpec.describe "Admin CSV import", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:event) { create(:event) }

  before { sign_in User.create!(email: "ga-imports@example.com", name: "Global Admin", global_role: "global_admin", admin_console_beta: false) }

  def upload(content)
    post admin_event_imports_path(event.slug), params: {
      csv_file: Rack::Test::UploadedFile.new(StringIO.new(content), "text/csv", original_filename: "participants.csv"),
      send_invitations: "0"
    }
  end

  def last_batch
    event.import_batches.order(:created_at).last
  end

  it "matches headers ignoring case, spacing and aliases, then imports what the preview promised" do
    upload(" EMAIL address ,first  name,LAST NAME\nAda@Example.com,Ada,Lovelace\nnofirst@example.com,,Hopper\n")
    follow_redirect!
    expect(response.body).to include("ada@example.com", "Missing first name")

    perform_enqueued_jobs(only: ProcessImportBatchJob) do
      post confirm_admin_event_import_path(event.slug, last_batch)
    end

    expect(event.participants.pluck(:email)).to eq([ "ada@example.com" ])
  end

  it "reads Windows-1252 and UTF-16 exports" do
    upload("Email,First Name,Last Name\njose@example.com,José,Müller\n".encode(Encoding::Windows_1252).b)
    expect(last_batch.rows_data.first).to include("legal_first_name" => "José")
    expect(response).to redirect_to(preview_admin_event_import_path(event.slug, last_batch, read_as: "windows-1252"))

    upload("﻿Email\tFirst Name\tLast Name\nzoe@example.com\tZoë\tExample\n".encode(Encoding::UTF_16LE).b)
    expect(last_batch.rows_data.first).to include("email" => "zoe@example.com", "legal_first_name" => "Zoë")
  end

  it "explains a file it can't read instead of failing" do
    upload("Email,First Name\n\"broken@example.com,Pat\n")
    expect(flash[:alert]).to start_with("This file isn't a valid CSV")

    upload("Email,First Name\nx@example.com,\x81\x8D\n".b)
    expect(flash[:alert]).to include("CSV UTF-8")
  end

  it "previews the rows the job would reject, with the reason" do
    create(:participant_event, participant: create(:participant, email: "registered@example.com"), event: event)
    create(:ban, email: "banned@example.com")
    create(:guardian, email: "known-parent@example.com")

    upload("Email,First Name,Last Name,Birthday,Parent Email,Parent First Name,Parent Last Name,Emergency Contact First Name,Emergency Contact Phone\n" \
           "registered@example.com,Re,Gistered,,,,,,\n" \
           "not-an-email,No,Email,,,,,,\n" \
           "banned@example.com,Ban,Ned,,,,,,\n" \
           "adult@example.com,Ad,Ult,1/2/1990,,,,,\n" \
           "noparent@example.com,No,Parent,,mum@example.com,,,,\n" \
           "badparent@example.com,Bad,Parent,,not-an-email,,,,\n" \
           "badphone@example.com,Bad,Phone,,,,,Em,not a phone\n" \
           "known@example.com,Known,Parent,,known-parent@example.com,,,Em,+14155550132\n" \
           "self@example.com,Self,Parent,,SELF@example.com,,,,\n" \
           "self@example.com,Self,Again,,,,,,\n")
    follow_redirect!

    skipped = controller.instance_variable_get(:@skipped_rows).to_h { |row| [ row[:email], row[:reason] ] }
    expect(skipped).to eq(
      "registered@example.com" => "Already registered",
      "not-an-email" => "Invalid email address",
      "banned@example.com" => "Banned from events",
      "adult@example.com" => "19 or older during this event",
      "noparent@example.com" => "Missing parent first name and parent last name",
      "badparent@example.com" => "Invalid parent email",
      "badphone@example.com" => "Invalid emergency contact phone",
      "self@example.com" => "Same email as row 10"
    )
    expect(controller.instance_variable_get(:@valid_rows).pluck(:email)).to eq([ "known@example.com", "self@example.com" ])
  end
end
