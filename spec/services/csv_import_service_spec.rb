require "rails_helper"

RSpec.describe CsvImportService do
  let(:event) { create(:event) }
  let(:service) { described_class.new(event: event, send_invitations: false) }

  let(:valid_csv) do
    headers = [
      "Email", "First Name", "Last Name", "Preferred Name", "Slack ID", "Pronouns", "Gender",
      "Phone Number", "Birthday", "Address Line 1", "Address Line 2", "City", "State", "ZIP Code",
      "Country", "T-Shirt Size", "Parent First Name", "Parent Last Name", "Parent Email", "Parent Phone",
      "Emergency Contact First Name", "Emergency Contact Last Name", "Emergency Contact Email",
      "Emergency Contact Phone", "Emergency Contact Relationship",
      "Do you have any dietary requirements we need to know about?",
      "Do you have any special requirements e.g. medication, or disabilities that we need to be aware of?",
      "How are you getting to Prototype?", "Starting Address", "How much does your flight cost?",
      "Flight Reimbursement Amount", "How many flights are on your itinerary for your journey to SFO / SJO / OAK?",
      "Flight 1 Departing Airport", "Flight 1 Arriving Airport", "Flight 1 Airline Code", "Flight 1 Flight Number",
      "Flight 1 Departing Date", "Flight 2 Departing Airport", "Flight 2 Arriving Airport", "Flight 2 Airline Code",
      "Flight 2 Flight Number", "Flight 2 Departing Date", "Flight 3 Departing Airport", "Flight 3 Arriving Airport",
      "Flight 3 Airline Code", "Flight 3 Flight Number", "Flight 3 Departing Date", "Final Departure Airport",
      "Final Airline Code", "Final Flight Number", "Flight Departure Date"
    ]
    values = [
      "test@example.com", "John", "Doe", "Johnny", "U12345", "He/Him", "male", "+14155550123", "1/15/08",
      "123 Main St", "", "San Francisco", "California", "94102", "United States", "M", "Jane", "Doe",
      "jane@example.com", "+14155550176", "Bob", "Smith", "bob@example.com", "+14155550155", "Uncle",
      "Allergic to peanuts", "Takes daily medication", "Flight", "", "", "", "2", "SFO", "ORD", "UA", "123",
      "12/19/25", "ORD", "JFK", "UA", "456", "12/19/25", "", "", "", "", "", "JFK", "UA", "789", "12/21/25"
    ]
    CSV.generate do |csv|
      csv << headers
      csv << values
    end
  end

  let(:minimal_csv) do
    <<~CSV
      Email,First Name,Last Name
      minimal@example.com,Jane,Smith
    CSV
  end

  let(:empty_rows_csv) do
    <<~CSV
      Email,First Name,Last Name
      valid@example.com,Valid,User
      ,,,
      ,,,
      another@example.com,Another,User
    CSV
  end

  describe "#import" do
    context "with valid data" do
      it "creates a participant" do
        expect { service.import(valid_csv) }.to change(Participant, :count).by(1)
      end

      it "creates a participant_event" do
        expect { service.import(valid_csv) }.to change(ParticipantEvent, :count).by(1)
      end

      it "sets participant attributes correctly" do
        service.import(valid_csv)
        participant = Participant.find_by(email: "test@example.com")

        expect(participant.legal_first_name).to eq("John")
        expect(participant.legal_last_name).to eq("Doe")
        expect(participant.preferred_name).to eq("Johnny")
        expect(participant.pronouns).to eq("He/Him")
        expect(participant.tshirt_size).to eq("M")
        expect(participant.address_line_1).to eq("123 Main St")
        expect(participant.city).to eq("San Francisco")
        expect(participant.state).to eq("California")
        expect(participant.postal_code).to eq("94102")
        expect(participant.country_of_residence).to eq("United States")
      end

      it "parses date of birth correctly" do
        service.import(valid_csv)
        participant = Participant.find_by(email: "test@example.com")

        expect(participant.date_of_birth).to eq(Date.new(2008, 1, 15))
      end

      it "creates a guardian" do
        expect { service.import(valid_csv) }.to change(Guardian, :count).by(1)
      end

      it "creates guardian_participant_event" do
        expect { service.import(valid_csv) }.to change(GuardianParticipantEvent, :count).by(1)
      end

      it "sets guardian attributes correctly" do
        service.import(valid_csv)
        guardian = Guardian.find_by(email: "jane@example.com")

        expect(guardian.legal_first_name).to eq("Jane")
        expect(guardian.legal_last_name).to eq("Doe")
      end

      it "creates emergency contact" do
        expect { service.import(valid_csv) }.to change(EmergencyContact, :count).by(1)
      end

      it "sets emergency contact attributes correctly" do
        service.import(valid_csv)
        contact = EmergencyContact.last

        expect(contact.name).to eq("Bob Smith")
        expect(contact.email).to eq("bob@example.com")
        expect(contact.relationship).to eq("Uncle")
      end

      it "creates dietary record" do
        expect { service.import(valid_csv) }.to change(Dietary, :count).by(1)
      end

      it "creates medical record" do
        expect { service.import(valid_csv) }.to change(Medical, :count).by(1)
      end

      it "creates accommodation with gender" do
        expect { service.import(valid_csv) }.to change(Accommodation, :count).by(1)

        accommodation = Accommodation.last
        expect(accommodation.gender_identity).to eq("male")
      end

      it "creates inbound travel with flight legs" do
        service.import(valid_csv)
        participant_event = ParticipantEvent.last
        travel = participant_event.travel_inbound

        expect(travel).to be_present
        expect(travel.mode).to eq("plane")
        expect(travel.travel_legs.count).to eq(2)

        first_leg = travel.travel_legs.find_by(position: 0)
        expect(first_leg.departure_airport).to eq("SFO")
        expect(first_leg.arrival_airport).to eq("ORD")
        expect(first_leg.flight_code).to eq("UA123")

        second_leg = travel.travel_legs.find_by(position: 1)
        expect(second_leg.departure_airport).to eq("ORD")
        expect(second_leg.arrival_airport).to eq("JFK")
        expect(second_leg.flight_code).to eq("UA456")
      end

      it "creates outbound travel" do
        service.import(valid_csv)
        participant_event = ParticipantEvent.last
        travel = participant_event.travel_outbound

        expect(travel).to be_present
        expect(travel.mode).to eq("plane")
        expect(travel.travel_legs.count).to eq(1)

        leg = travel.travel_legs.first
        expect(leg.departure_airport).to eq("JFK")
        expect(leg.flight_code).to eq("UA789")
      end

      it "returns successful result" do
        result = service.import(valid_csv)

        expect(result.success?).to be true
        expect(result.imported_count).to eq(1)
        expect(result.skipped_count).to eq(0)
        expect(result.errors).to be_empty
      end
    end

    context "with minimal data" do
      it "imports participant with just email and name" do
        result = service.import(minimal_csv)

        expect(result.success?).to be true
        expect(Participant.find_by(email: "minimal@example.com")).to be_present
      end

      it "does not create associated records when data is missing" do
        service.import(minimal_csv)

        expect(Guardian.count).to eq(0)
        expect(EmergencyContact.count).to eq(0)
        expect(Dietary.count).to eq(0)
        expect(Medical.count).to eq(0)
        expect(Travel.count).to eq(0)
      end
    end

    context "with empty rows" do
      it "skips empty rows" do
        result = service.import(empty_rows_csv)

        expect(result.imported_count).to eq(2)
        expect(Participant.count).to eq(2)
      end
    end

    context "when participant already exists for event" do
      before do
        participant = create(:participant, email: "test@example.com")
        create(:participant_event, participant: participant, event: event)
      end

      it "skips duplicate registrations" do
        result = service.import(valid_csv)

        expect(result.skipped_count).to eq(1)
        expect(result.imported_count).to eq(0)
      end

      it "reports error for duplicate" do
        result = service.import(valid_csv)

        expect(result.errors.first[:error]).to include("Already registered")
      end
    end

    context "when participant exists but not for this event" do
      let(:other_event) { create(:event) }

      before do
        participant = create(:participant, email: "test@example.com", legal_first_name: "Old")
        create(:participant_event, participant: participant, event: other_event)
      end

      it "updates existing participant and creates new participant_event" do
        result = service.import(valid_csv)

        expect(result.imported_count).to eq(1)
        expect(ParticipantEvent.where(event: event).count).to eq(1)

        participant = Participant.find_by(email: "test@example.com")
        expect(participant.legal_first_name).to eq("John")
      end
    end

    context "with car travel mode" do
      let(:car_csv) do
        <<~CSV
          Email,First Name,Last Name,How are you getting to Prototype?
          car@example.com,Car,Person,Car
        CSV
      end

      it "creates travel with car mode" do
        service.import(car_csv)
        travel = Travel.last

        expect(travel.mode).to eq("car")
      end
    end

    context "with invitations enabled" do
      let(:service_with_invites) { described_class.new(event: event, send_invitations: true) }

      it "sends invitation email" do
        allow(ParticipantMailer).to receive_message_chain(:invitation, :deliver_later)

        service_with_invites.import(minimal_csv)

        expect(ParticipantMailer).to have_received(:invitation).with(
          email: "minimal@example.com",
          event: event,
          participant: an_instance_of(Participant)
        )
      end
    end
  end

  describe "date parsing" do
    let(:date_csv) do
      <<~CSV
        Email,First Name,Last Name,Birthday
        date1@example.com,Test,One,1/8/09
        date2@example.com,Test,Two,01/15/2008
        date3@example.com,Test,Three,2008-05-20
      CSV
    end

    it "parses various date formats" do
      service.import(date_csv)

      expect(Participant.find_by(email: "date1@example.com").date_of_birth).to eq(Date.new(2009, 1, 8))
      expect(Participant.find_by(email: "date2@example.com").date_of_birth).to eq(Date.new(2008, 1, 15))
      expect(Participant.find_by(email: "date3@example.com").date_of_birth).to eq(Date.new(2008, 5, 20))
    end
  end

  describe "t-shirt size normalization" do
    let(:tshirt_csv) do
      <<~CSV
        Email,First Name,Last Name,T-Shirt Size
        xs@example.com,Test,XS,xs
        xl@example.com,Test,XL,XL
        xxl@example.com,Test,XXL,2xl
      CSV
    end

    it "normalizes t-shirt sizes" do
      service.import(tshirt_csv)

      expect(Participant.find_by(email: "xs@example.com").tshirt_size).to eq("XS")
      expect(Participant.find_by(email: "xl@example.com").tshirt_size).to eq("XL")
      expect(Participant.find_by(email: "xxl@example.com").tshirt_size).to eq("XXL")
    end
  end
end
