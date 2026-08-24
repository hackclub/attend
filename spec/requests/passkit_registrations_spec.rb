require "rails_helper"

RSpec.describe "Passkit device registrations", type: :request do
  let(:pass) do
    Passkit::Pass.create!(
      klass: "Passkit::EventTicket",
      serial_number: SecureRandom.uuid,
      authentication_token: SecureRandom.hex(16)
    )
  end
  let(:device_id) { SecureRandom.hex(16) }
  let(:headers) { { "Authorization" => "ApplePass #{pass.authentication_token}" } }

  def register
    post "/passkit/api/v1/devices/#{device_id}/registrations/pass.com.hackclub.attend/#{pass.serial_number}",
      params: { pushToken: "token-123" }.to_json,
      headers: headers.merge("CONTENT_TYPE" => "application/json")
  end

  it "registers a new device" do
    register

    expect(response).to have_http_status(:created)
    expect(Passkit::Device.find_by(identifier: device_id)).to be_present
  end

  it "returns ok when the device is already registered" do
    register
    register

    expect(response).to have_http_status(:ok)
    expect(Passkit::Registration.where(passkit_pass_id: pass.id).count).to eq(1)
  end

  it "recovers when a concurrent registration wins the uniqueness race (ATTEND-7R)" do
    # Simulate the race: the first find_or_create_by! loses to a concurrent
    # request whose row commits between our find and create, raising
    # RecordInvalid from the gem's uniqueness validation.
    calls = 0
    allow(Passkit::Device).to receive(:find_or_create_by!).and_wrap_original do |original, *args, &block|
      calls += 1
      if calls == 1
        Passkit::Device.create!(identifier: device_id, push_token: "winner-token")
        record = Passkit::Device.new(identifier: device_id)
        record.errors.add(:identifier, :taken)
        raise ActiveRecord::RecordInvalid, record
      end
      original.call(*args, &block)
    end

    register

    expect(response).to have_http_status(:created)
    expect(Passkit::Device.where(identifier: device_id).count).to eq(1)
    expect(Passkit::Registration.where(passkit_pass_id: pass.id).count).to eq(1)
  end

  it "does not retry forever when the failure is not transient" do
    allow(Passkit::Device).to receive(:find_or_create_by!) do
      record = Passkit::Device.new
      record.errors.add(:identifier, :taken)
      raise ActiveRecord::RecordInvalid, record
    end

    register

    expect(response).to have_http_status(:unprocessable_content)
    expect(Passkit::Device).to have_received(:find_or_create_by!).twice
  end
end
