require "rails_helper"

RSpec.describe VisaLetterApplication do
  let(:event) do
    create(:event, name: "Fictional Hackathon", venue_name: "Example Hall", location_address: "1 Example Street",
      location_city: "Boston", location_country: "United States", timezone: "Eastern Time (US & Canada)",
      starts_at: Time.utc(2027, 3, 5, 15), ends_at: Time.utc(2027, 3, 7, 22))
  end
  let(:reviewer) { create(:user) }

  before { create(:visa_letter_template, :default) }

  it "gives each application an Envoy-style reference number and verification code" do
    application = create(:visa_letter_application, event: event)

    expect(application.reference_number).to match(/\AHC-[A-Z0-9]{8}\z/)
    expect(application.verification_code).to match(/\A[0-9A-F]{32}\z/)
    expect(application.submitted_at).to be_present
    expect(application).to be_pending
  end

  it "keeps the applicant's details encrypted and finds them by email in any case" do
    application = create(:visa_letter_application, event: event, email: "Ada.Example@Example.com ")

    raw = described_class.connection.select_one(
      described_class.sanitize_sql_array([ "SELECT full_name, email, nationality, address FROM visa_letter_applications WHERE id = ?", application.id ])
    )
    expect(raw.values).not_to include("Ada Example", "ada.example@example.com", "Exampleland")
    expect(application.reload.email).to eq("ada.example@example.com")
    expect(described_class.where(email: "ADA.EXAMPLE@EXAMPLE.COM")).to contain_exactly(application)
  end

  it "needs a signed-in applicant, except for applications imported from Envoy" do
    expect(build(:visa_letter_application, event: event, user: nil, email: "someone@example.com")).not_to be_valid
    expect(build(:visa_letter_application, :imported, event: event, email: "someone@example.com")).to be_valid
  end

  it "allows one application per person per event" do
    application = create(:visa_letter_application, event: event)

    duplicate = build(:visa_letter_application, event: event, user: application.user)
    expect(duplicate).not_to be_valid
    expect(build(:visa_letter_application, user: application.user)).to be_valid
  end

  it "needs applicants to be at least 13, as Envoy did, but keeps what Envoy already accepted" do
    expect(build(:visa_letter_application, event: event, date_of_birth: 12.years.ago.to_date)).not_to be_valid
    expect(build(:visa_letter_application, :imported, event: event, email: "young@example.com", date_of_birth: 12.years.ago.to_date)).to be_valid
  end

  it "refuses an applicant whose email is banned" do
    create(:ban, email: "banned-applicant@example.com")
    user = create(:user, email: "banned-applicant@example.com")

    application = build(:visa_letter_application, event: event, user: user)
    expect(application).not_to be_valid
    expect(application.errors[:email]).to include("is banned from events")

    # A letter Envoy already issued still has to verify.
    expect(build(:visa_letter_application, :imported, event: event, email: "banned-applicant@example.com")).to be_valid
  end

  describe "review" do
    let(:application) { create(:visa_letter_application, event: event) }

    it "approves a pending application" do
      application.approve!(by: reviewer, notes: "Looks right")

      expect(application.reload).to be_approved
      expect(application).to have_attributes(reviewed_by: reviewer, admin_notes: "Looks right")
      expect(application.reviewed_at).to be_present
    end

    it "won't approve someone banned after they applied" do
      create(:ban, email: application.email)

      expect { application.approve!(by: reviewer) }.to raise_error(described_class::InvalidTransition, /banned/)
      expect(application.reload).to be_pending
    end

    it "rejects with a reason, and lets a hard rejection be softened" do
      application.reject!(by: reviewer, reason: "Not a participant", type: :hard)
      expect(application.reload).to be_hard_rejected

      application.downgrade_rejection!
      expect(application.reload).to be_soft_rejected
    end

    it "needs a reason to reject" do
      expect { application.reject!(by: reviewer, reason: "") }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "only moves forward from pending" do
      application.reject!(by: reviewer, reason: "Duplicate")

      expect { application.approve!(by: reviewer) }.to raise_error(described_class::InvalidTransition)
      expect { application.reject!(by: reviewer, reason: "Again") }.to raise_error(described_class::InvalidTransition)
    end
  end

  describe "#issue_letter!" do
    let(:application) { create(:visa_letter_application, event: event).tap { |a| a.approve!(by: reviewer) } }

    it "freezes the event details, attaches the letter and marks it sent" do
      application.issue_letter!(issued_on: Date.new(2026, 10, 28))

      application.reload
      expect(application).to be_letter_sent
      expect(application).to have_attributes(
        letter_event_name: "Fictional Hackathon", letter_venue: "Example Hall", letter_address: "1 Example Street",
        letter_city: "Boston", letter_country: "United States",
        letter_starts_on: Date.new(2027, 3, 5), letter_ends_on: Date.new(2027, 3, 7), letter_issued_on: Date.new(2026, 10, 28)
      )
      expect(application.letter_sent_at).to be_present
      expect(application.letter_pdf).to be_attached
      expect(application.letter_pdf.filename.to_s).to eq("visa-letter-#{application.reference_number}.pdf")
    end

    it "keeps what the letter says when the event changes later" do
      application.issue_letter!
      event.update!(name: "Renamed Hackathon", starts_at: Time.utc(2027, 4, 1, 15), ends_at: Time.utc(2027, 4, 2, 22))

      expect(application.reload).to have_attributes(letter_event_name: "Fictional Hackathon", letter_starts_on: Date.new(2027, 3, 5))
    end

    it "won't let the printed details change once the letter is sent" do
      application.issue_letter!

      application.full_name = "Someone Else"
      expect(application).not_to be_valid
      expect(application.errors[:full_name]).to include("can't change once the letter has been sent")

      application.reload.admin_notes = "Called the embassy"
      expect(application).to be_valid
    end

    it "uses the event's own template over the global default" do
      create(:visa_letter_template, event: event, name: "Event wording")

      expect(VisaLetterTemplate.for_event(event).name).to eq("Event wording")
    end

    it "raises instead of leaving the application approved when there's no template" do
      VisaLetterTemplate.update_all(active: false)

      expect { application.issue_letter! }.to raise_error(described_class::InvalidTransition, /no active visa letter template/)
      expect(application.reload).to be_approved
    end

    it "only issues letters for approved applications" do
      pending_application = create(:visa_letter_application, event: event)

      expect { pending_application.issue_letter! }.to raise_error(described_class::InvalidTransition)
    end
  end

  describe "its registration" do
    let(:user) { create(:user, email: "ada.example@example.com") }
    let(:application) { create(:visa_letter_application, event: event, user: user) }

    it "is the one on their Hack Club account, whichever came first" do
      expect(application.registration).to be_nil

      registration = create(:participant_event, event: event, participant: create(:participant, user: user, email: "ada.personal@example.com"))
      create(:participant_event, participant: registration.participant)

      expect(application.reload.registration).to eq(registration)
      expect(registration.reload.visa_letter_application).to eq(application)
    end

    it "is one under their email, in any case, unless it's someone else's account" do
      registration = create(:participant_event, event: event, participant: create(:participant, email: "Ada.Example@example.com"))
      expect(application.registration).to eq(registration)
      expect(registration.visa_letter_application).to eq(application)

      registration.participant.update!(user: create(:user))
      expect(application.reload.registration).to be_nil
      expect(registration.reload.visa_letter_application).to be_nil
    end

    it "finds an unclaimed Envoy import by email" do
      imported = create(:visa_letter_application, :imported, event: event, email: "imported@example.com")
      registration = create(:participant_event, event: event, participant: create(:participant, email: "imported@example.com"))

      expect(imported.registration).to eq(registration)
      expect(registration.visa_letter_application).to eq(imported)

      # Still theirs once they've signed in, before they claim the import.
      registration.participant.update!(user: create(:user, email: "imported@example.com"))
      expect(imported.registration).to eq(registration)
      expect(registration.reload.visa_letter_application).to eq(imported)
    end
  end

  describe "#letter_date_range" do
    def range(starts, ends)
      described_class.new(letter_starts_on: Date.parse(starts), letter_ends_on: ends && Date.parse(ends)).letter_date_range
    end

    it "reads naturally for one day, one month, one year and across years" do
      expect(range("2027-03-05", "2027-03-05")).to eq("March 5, 2027")
      expect(range("2027-03-05", nil)).to eq("March 5, 2027")
      expect(range("2027-03-05", "2027-03-07")).to eq("March 5–7, 2027")
      expect(range("2027-03-30", "2027-04-02")).to eq("March 30 – April 2, 2027")
      expect(range("2027-12-30", "2028-01-02")).to eq("December 30, 2027 – January 2, 2028")
    end
  end

  describe "applying again" do
    let(:application) { create(:visa_letter_application, event: event) }

    it "puts a soft-rejected application back in review with the corrected details" do
      application.reject!(by: reviewer, reason: "Wrong name")

      application.resubmit!({ full_name: "Ada Q. Example" })

      expect(application.reload).to have_attributes(status: "pending", full_name: "Ada Q. Example", rejection_reason: nil, reviewed_by: nil)
    end

    it "leaves it rejected, with its reason, while the corrected details have something wrong" do
      application.reject!(by: reviewer, reason: "Wrong name")

      expect { application.resubmit!({ full_name: "Ada Q. Example", phone: "not a phone" }) }.to raise_error(ActiveRecord::RecordInvalid)

      expect(application).to have_attributes(status: "rejected", rejection_reason: "Wrong name", full_name: "Ada Q. Example")
      expect(application.errors[:phone]).to be_present
      expect(application.reload).to have_attributes(status: "rejected", rejection_reason: "Wrong name")
    end

    it "only reopens a hard rejection when staff have invited them again" do
      application.reject!(by: reviewer, reason: "Not eligible", type: :hard)

      expect { application.resubmit!({}) }.to raise_error(described_class::InvalidTransition)
      application.resubmit!({}, overriding_hard_rejection: true)
      expect(application.reload).to be_pending
    end
  end

  describe ".prefill_for" do
    it "starts from the legal details Hack Club Auth holds, then the Attend profile" do
      user = create(:user, oidc_claims: { "legal_first_name" => "Ada", "legal_last_name" => "Example", "birthdate" => "2008-04-01",
        "addresses" => [ { "id" => "addr!a", "line_1" => "2 Sample Road", "city" => "Example City", "postal_code" => "EX1 2AB", "country" => "GB" } ] })
      create(:participant, user: user, email: user.email, phone: "+12025550123")

      expect(described_class.locked_by_hack_club_auth(user).keys).to contain_exactly(:date_of_birth)
      expect(described_class.prefill_for(user)).to include(
        full_name: "Ada Example", date_of_birth: Date.new(2008, 4, 1), phone: "+12025550123",
        address: "2 Sample Road\nExample City, EX1 2AB\nUnited Kingdom"
      )
    end

    it "leaves citizenship out: the country they live in needn't be it" do
      user = create(:user, oidc_claims: { "addresses" => [ { "id" => "addr!a", "line_1" => "2 Sample Road", "city" => "Example City", "country" => "AE" } ] })
      create(:participant, user: user, email: user.email, country_of_residence: "United Arab Emirates")

      expect(described_class.prefill_for(user)).not_to have_key(:nationality)
    end

    it "uses the locked fields and addresses it's given rather than working them out again" do
      user = create(:user, oidc_claims: { "birthdate" => "2008-04-01" })

      prefill = described_class.prefill_for(user, locked: {}, addresses: { "addr!a" => "2 Sample Road" })

      expect(prefill).to include(address: "2 Sample Road")
      expect(prefill).not_to have_key(:date_of_birth)
    end
  end

  describe ".hack_club_auth_addresses" do
    it "lists every address on the account, primary first, or the one an older sign-in kept" do
      user = create(:user, oidc_claims: { "addresses" => [
        { "id" => "addr!b", "line_1" => "3 Example Lane", "city" => "Sample Town", "country" => "GB" },
        { "id" => "addr!a", "line_1" => "2 Sample Road", "line_2" => "Flat 1", "city" => "Example City", "postal_code" => "EX1 2AB", "country" => "GB", "primary" => true }
      ] })

      expect(described_class.hack_club_auth_addresses(user)).to eq(
        "addr!a" => "2 Sample Road\nFlat 1\nExample City, EX1 2AB\nUnited Kingdom",
        "addr!b" => "3 Example Lane\nSample Town\nUnited Kingdom"
      )

      user.update!(oidc_claims: { "address" => { "line_1" => "2 Sample Road", "city" => "Example City", "country" => "GB" } })
      expect(described_class.hack_club_auth_addresses(user).values).to eq([ "2 Sample Road\nExample City\nUnited Kingdom" ])

      user.update!(oidc_claims: {})
      expect(described_class.hack_club_auth_addresses(user)).to eq({})
    end

    it "keys them by strings the form sends back, each staying with its address however the list changes" do
      user = create(:user, oidc_claims: { "addresses" => [ { "id" => 42, "line_1" => "2 Sample Road", "city" => "Example City" } ] })
      expect(described_class.hack_club_auth_addresses(user).keys).to eq([ "42" ])

      home = { "line_1" => "2 Sample Road", "city" => "Example City" }
      school = { "line_1" => "3 Example Lane", "city" => "Sample Town" }
      user.update!(oidc_claims: { "addresses" => [ home, school ] })
      keys_by_address = described_class.hack_club_auth_addresses(user).invert

      user.update!(oidc_claims: { "addresses" => [ school, home ] })
      expect(described_class.hack_club_auth_addresses(user).invert).to eq(keys_by_address)
      expect(keys_by_address.values).to all(be_a(String))
      expect(keys_by_address.values).not_to include("0", "1")
    end
  end

  describe ".claim_imported_for" do
    it "gives Envoy's applications under a Hack Club account's email to that account" do
      user = create(:user, email: "ada@example.com", hack_club_account_id: "ident!ada")
      imported = create(:visa_letter_application, :imported, event: event, email: "ADA@example.com")
      placeholder = create(:user, email: "placeholder@example.com")
      unclaimed = create(:visa_letter_application, :imported, event: event, email: "placeholder@example.com")

      described_class.claim_imported_for(user)
      described_class.claim_imported_for(placeholder)

      expect(imported.reload.user).to eq(user)
      expect(unclaimed.reload.user).to be_nil
    end
  end
end
