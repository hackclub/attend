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

  describe "#record_visa_outcome!" do
    it "records the embassy's decision once the letter is out" do
      application = create(:visa_letter_application, event: event)
      expect { application.record_visa_outcome!(:granted) }.to raise_error(described_class::InvalidTransition)

      application.approve!(by: reviewer)
      application.issue_letter!
      application.record_visa_outcome!(:granted)

      expect(application.reload).to be_visa_granted
      expect(application.visa_outcome_recorded_at).to be_present
    end
  end

  describe "#offer_place!" do
    let(:user) { create(:user, email: "ada.example@example.com", oidc_claims: { "legal_first_name" => "Ada", "legal_last_name" => "Example" }) }
    let(:application) { create(:visa_letter_application, event: event, user: user, full_name: "Ada Example") }

    def send_letter
      application.approve!(by: reviewer)
      application.issue_letter!
    end

    it "registers someone whose visa was granted as invited, and issues an invitation for the caller to send" do
      send_letter
      application.record_visa_outcome!(:granted)

      invitation = nil
      expect { invitation = application.offer_place! }.not_to have_enqueued_mail(ParticipantMailer, :invitation)

      registration = application.reload.participant_event
      expect(registration).to have_attributes(event: event, status: "invited")
      expect(registration.participant).to have_attributes(email: "ada.example@example.com", legal_first_name: "Ada",
        legal_last_name: "Example", date_of_birth: Date.new(2008, 4, 1), phone: "+12025550123")
      expect(application.invitation).to eq(invitation)
      expect(invitation).to have_attributes(email: "ada.example@example.com", name: "Ada Example", accepted_at: nil)
    end

    it "only fills in what an existing participant is missing, and says so" do
      existing = create(:participant, user: user, email: "ada.personal@example.com", legal_first_name: "Ada",
        legal_last_name: "Lovelace", phone: nil, date_of_birth: Date.new(2008, 1, 1))
      send_letter
      application.record_visa_outcome!(:granted)

      filled = nil
      application.offer_place! { |participant| filled = participant.previous_changes.keys }

      expect(application.reload.participant_event.participant).to eq(existing)
      expect(existing.reload).to have_attributes(legal_last_name: "Lovelace", date_of_birth: Date.new(2008, 1, 1), phone: "+12025550123")
      expect(filled).to include("phone")
    end

    it "splits a name Hack Club Auth doesn't know at the first space" do
      application.update!(full_name: "Maria de la Cruz")
      send_letter
      application.record_visa_outcome!(:granted)

      application.offer_place!

      expect(application.reload.participant_event.participant).to have_attributes(legal_first_name: "Maria", legal_last_name: "de la Cruz")
    end

    it "needs staff to override before the visa is granted, and only offers one place" do
      expect { application.offer_place! }.to raise_error(described_class::InvalidTransition, /visa is granted/)
      expect(application.reload.participant_event).to be_nil

      application.offer_place!(override: true)
      expect(application.reload.participant_event).to be_present

      expect { application.offer_place!(override: true) }.to raise_error(described_class::InvalidTransition, /already have a place/)
    end

    it "links a registration they already have instead of inviting them again" do
      participant = create(:participant, user: user, email: user.email)
      registration = create(:participant_event, participant: participant, event: event, status: :complete)

      expect(application.offer_place!(override: true)).to be_nil

      expect(application.reload).to have_attributes(participant_event: registration, invitation: nil)
      expect(registration.reload).to be_complete
    end

    it "leaves nothing behind when registering fails" do
      allow(Invitation).to receive(:issue!).and_raise(ActiveRecord::RecordInvalid.new(Invitation.new))

      expect { application.offer_place!(override: true) }.to raise_error(ActiveRecord::RecordInvalid)

      expect(application.reload.participant_event).to be_nil
      expect(ParticipantEvent.where(event: event)).to be_empty
    end
  end

  describe "the registration's travel" do
    let(:participant) { create(:participant) }
    let(:registration) { create(:participant_event, participant: participant, event: event) }
    let(:application) { create(:visa_letter_application, event: event, participant_event: registration) }

    it "follows the letter and the embassy's decision on the inbound travel, created if missing" do
      expect(registration.travel_inbound).to be_nil

      application.approve!(by: reviewer)
      expect(registration.reload.travel_inbound).to be_nil

      application.issue_letter!
      expect(registration.reload.travel_inbound).to have_attributes(visa_status: "applied", visa_required: true)

      application.record_visa_outcome!(:granted)
      expect(registration.reload.travel_inbound.visa_status).to eq("approved")

      application.record_visa_outcome!(:denied)
      expect(registration.reload.travel_inbound.visa_status).to eq("denied")
      expect(registration.travels.count).to eq(1)
    end

    it "writes over what the participant chose once the application is linked" do
      unlinked = create(:visa_letter_application, event: event)
      unlinked.approve!(by: reviewer)
      unlinked.issue_letter!
      travel = Travel.create!(participant_event: registration, direction: :inbound, visa_status: :pending, mode: :plane, arrangement_status: :provisional)
      expect(travel.read_attribute_before_type_cast(:visa_status)).to eq("not_applied")

      unlinked.update!(participant_event: registration)

      expect(travel.reload).to have_attributes(visa_status: "applied", mode: "plane")
    end

    it "still issues the letter when the travel row fails a rule about its other details" do
      travel = Travel.create!(participant_event: registration, direction: :inbound, mode: :plane, arrangement_status: :provisional)
      travel.update_columns(arrangement_status: "confirmed")
      expect(travel.reload).not_to be_valid

      application.approve!(by: reviewer)
      application.issue_letter!

      expect(application.reload).to be_letter_sent
      expect(travel.reload.visa_status).to eq("applied")
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
        "address" => { "line_1" => "2 Sample Road", "city" => "Example City", "postal_code" => "EX1 2AB", "country" => "GB" } })
      create(:participant, user: user, email: user.email, phone: "+12025550123")

      expect(described_class.locked_by_hack_club_auth(user).keys).to contain_exactly(:date_of_birth, :address)
      expect(described_class.prefill_for(user)).to include(
        full_name: "Ada Example", date_of_birth: Date.new(2008, 4, 1), phone: "+12025550123",
        address: "2 Sample Road\nExample City, EX1 2AB\nUnited Kingdom", nationality: "United Kingdom"
      )
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
