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
end
