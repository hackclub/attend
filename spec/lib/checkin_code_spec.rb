require "rails_helper"

RSpec.describe CheckinCode do
  let(:key) { described_class.generate_key }
  let(:participant_event) { create(:participant_event) }
  let(:event) { participant_event.event }

  after { described_class.reset_keyring! }

  def token_bytes(code)
    described_class.base32_decode(described_class.strip_prefix(code).delete_prefix("T."))
  end

  def encode(bytes)
    "T.#{described_class.base32_encode(bytes)}"
  end

  context "without signing keys" do
    before { described_class.keyring = {} }

    it "keeps the old unsigned code" do
      expect(described_class.signing_enabled?).to be(false)
      expect(described_class.for(participant_event)).to eq("attend://checkin/#{participant_event.participant_id}")
      expect(described_class.public_keys).to eq({})
    end
  end

  context "with a signing key" do
    before { described_class.keyring = { 1 => key } }

    it "signs a code that names the registration, and nothing else" do
      code = described_class.for(participant_event)

      expect(code).to match(%r{\AATTEND://CHECKIN/T\.[A-Z2-7]{132}\z})
      expect(described_class.signed?(code)).to be(true)
      expect(token_bytes(code).bytesize).to eq(82)
      expect(described_class.verify!(code, event: event)).to eq(participant_event.id)
      expect(code).not_to include(participant_event.participant_id)
    end

    # Uppercase base32 keeps the QR in alphanumeric mode: as dense as the old
    # unsigned code, so no harder to scan.
    it "fits a QR no denser than the old unsigned code" do
      signed = RQRCode::QRCode.new(described_class.for(participant_event), level: :m)
      unsigned = RQRCode::QRCode.new("attend://checkin/#{participant_event.participant_id}")

      expect(signed.modules.size).to be <= unsigned.modules.size
    end

    it "round-trips base32" do
      [ "\x00", "\xFF\x01\x7F".b, SecureRandom.random_bytes(82) ].each do |bytes|
        expect(described_class.base32_decode(described_class.base32_encode(bytes)).b).to eq(bytes.b)
      end
      expect(described_class.base32_encode("foobar")).to eq("MZXW6YTBOI")
    end

    # A wallet pass is only pushed when its contents change.
    it "gives a registration the same code every time" do
      expect(described_class.for(participant_event)).to eq(described_class.for(participant_event))
    end

    it "verifies the token with or without the deep link prefix" do
      token = described_class.sign(event_id: event.id, participant_event_id: participant_event.id)

      expect(described_class.verify!(token, event: event)).to eq(participant_event.id)
      expect(described_class.verify!("  attend://checkin/#{token}\n", event: event)).to eq(participant_event.id)
      expect(described_class.verify!("ATTEND://CHECKIN/#{token.downcase}", event: event)).to eq(participant_event.id)
    end

    it "refuses a code for another event" do
      code = described_class.for(participant_event)

      expect { described_class.verify!(code, event: create(:event)) }.to raise_error(described_class::Invalid)
    end

    it "refuses a code whose registration was swapped after signing" do
      bytes = token_bytes(described_class.for(participant_event)).dup
      bytes[2, 16] = [ SecureRandom.uuid.delete("-") ].pack("H*")

      expect { described_class.verify!(encode(bytes), event: event) }.to raise_error(described_class::Invalid)
    end

    it "refuses a code signed with a key it doesn't hold" do
      forged = described_class.sign(event_id: event.id, participant_event_id: participant_event.id)
      described_class.keyring = { 1 => described_class.generate_key }

      expect { described_class.verify!(forged, event: event) }.to raise_error(described_class::Invalid)
    end

    it "refuses junk shaped like a signed code" do
      [ "T.", "T.!!!!", "T.#{"A" * 20}", "T.#{"1" * 132}", encode("\x02".b + ("\0" * 81)) ].each do |junk|
        expect { described_class.verify!(junk, event: event) }.to raise_error(described_class::Invalid), junk
      end
    end

    it "signs with the newest key and still accepts the older one" do
      old_code = described_class.for(participant_event)
      newer = described_class.generate_key
      described_class.keyring = { 1 => key, 2 => newer }

      new_code = described_class.for(participant_event)
      expect(token_bytes(new_code).getbyte(1)).to eq(2)
      expect(described_class.verify!(new_code, event: event)).to eq(participant_event.id)
      expect(described_class.verify!(old_code, event: event)).to eq(participant_event.id)
      expect(described_class.public_keys.keys).to eq([ 1, 2 ])
    end

    it "gives the scanner the public half only" do
      der = Base64.strict_decode64(described_class.public_keys.fetch(1))
      public_key = OpenSSL::PKey.read(der)

      expect(public_key.oid).to eq("ED25519")
      expect(described_class.private_key?(public_key)).to be(false)
      expect(public_key.public_to_der).to eq(key.public_to_der)
    end
  end

  # Every place a participant gets their QR code from puts the same code in
  # it, so a scanner never sees an unsigned one from a fresh ticket.
  describe "the tickets that carry it" do
    before { described_class.keyring = { 1 => key } }

    let(:code) { described_class.for(participant_event) }

    it "is the code on the Apple and Google wallet passes" do
      expect(Passkit::EventTicket.new(participant_event).barcodes.first[:message]).to eq(code)

      google = GoogleWallet::EventTicket.new(participant_event).send(:ticket_object)
      expect(google.options.dig(:barcode, :value)).to eq(code)
    end

    it "is the code in the ticket PDF" do
      expect(RQRCode::QRCode).to receive(:new).with(code, level: :m).and_call_original

      TicketPdfService.new(participant_event).generate
    end
  end

  describe ".load_keyring" do
    it "reads keys from credentials and rejects anything that isn't an Ed25519 private key" do
      pem = key.private_to_pem
      allow(Rails.application.credentials).to receive(:dig).with(:ticket_signing, :keys).and_return({ "3": pem })
      expect(described_class.load_keyring.keys).to eq([ 3 ])

      [ OpenSSL::PKey::RSA.generate(2048).to_pem, OpenSSL::PKey::EC.generate("prime256v1").to_pem ].each do |other|
        allow(Rails.application.credentials).to receive(:dig).with(:ticket_signing, :keys).and_return({ "1": other })
        expect { described_class.load_keyring }.to raise_error(ArgumentError, /Ed25519/)
      end

      allow(Rails.application.credentials).to receive(:dig).with(:ticket_signing, :keys).and_return({ "1": key.public_to_pem })
      expect { described_class.load_keyring }.to raise_error(ArgumentError, /private/)

      allow(Rails.application.credentials).to receive(:dig).with(:ticket_signing, :keys).and_return({ "0": pem })
      expect { described_class.load_keyring }.to raise_error(ArgumentError, /1-255/)
    end
  end
end
