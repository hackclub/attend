require "rails_helper"

RSpec.describe Passkit::EventTicket do
  let(:participant_event) { create(:participant_event) }
  let(:event) { participant_event.event }
  let(:pass) { described_class.new(participant_event) }
  let(:tmp_path) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmp_path) }

  # Smallest valid PNG (1x1 transparent pixel)
  ONE_PIXEL_PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
  ).freeze

  describe "#add_other_files" do
    it "does nothing when the event has no banner" do
      pass.add_other_files(tmp_path)
      expect(Dir.children(tmp_path)).to be_empty
    end

    it "writes strip images rendered from the event banner" do
      event.banner.attach(
        io: StringIO.new(ONE_PIXEL_PNG),
        filename: "banner.png",
        content_type: "image/png"
      )

      pass.add_other_files(tmp_path)

      expect(File.exist?(File.join(tmp_path, "strip.png"))).to be(true)
      expect(File.exist?(File.join(tmp_path, "strip@2x.png"))).to be(true)
      expect(File.size(File.join(tmp_path, "strip.png"))).to be > 0
    end

    it "writes poster artwork and background alongside the strip" do
      event.banner.attach(io: StringIO.new(ONE_PIXEL_PNG), filename: "banner.png", content_type: "image/png")

      pass.add_other_files(tmp_path)

      expect(Dir.children(tmp_path)).to include("artwork@2x.png", "artwork@3x.png", "background@2x.png", "background@3x.png")
    end

    it "writes poster logos from the event logo" do
      event.logo.attach(io: StringIO.new(ONE_PIXEL_PNG), filename: "logo.png", content_type: "image/png")

      pass.add_other_files(tmp_path)

      expect(Dir.children(tmp_path)).to contain_exactly("primaryLogo@2x.png", "primaryLogo@3x.png", "secondaryLogo@2x.png", "secondaryLogo@3x.png")
    end

    it "falls back to the series banner when the event has none" do
      series = create(:event_series)
      series.banner.attach(
        io: StringIO.new(ONE_PIXEL_PNG),
        filename: "series-banner.png",
        content_type: "image/png"
      )
      series.save!
      event.update!(event_series: series)

      pass.add_other_files(tmp_path)

      expect(File.exist?(File.join(tmp_path, "strip.png"))).to be(true)
      expect(File.size(File.join(tmp_path, "strip@2x.png"))).to be > 0
    end
  end

  describe "#featured_actions" do
    it "offers directions and the safety line when the venue has an Apple place id" do
      event.update_columns(apple_place_id: "IMOCKPLACE")

      expect(pass.featured_actions).to eq([
        { identifier: "directions", type: "place", placeIdentifier: "IMOCKPLACE" },
        { identifier: "safety-call", type: "call", url: "tel://+18556254225" }
      ])
    end

    it "offers only the safety line without a place id" do
      expect(pass.featured_actions.map { |a| a[:type] }).to eq([ "call" ])
    end
  end

  describe "#additional_pass_keys" do
    it "asks for the poster layout with the classic one as fallback" do
      keys = pass.additional_pass_keys
      expect(keys[:preferredStyleSchemes]).to eq(%w[posterEventTicket eventTicket])
      expect(keys[:eventLogoText]).to eq(event.name)
      expect(keys[:directionsInformationURL]).to start_with("https://maps.apple.com/?")
      expect(Rack::Utils.parse_query(URI(keys[:directionsInformationURL]).query)).to include("ll" => "37.7749,-122.4194", "q" => event.name)
    end

    it "labels the coordinate link with the venue name when there is one" do
      event.update_columns(venue_name: "Mock Hall")
      expect(Rack::Utils.parse_query(URI(pass.additional_pass_keys[:directionsInformationURL]).query)).to include("q" => "Mock Hall")
    end

    it "has no directions link without coordinates or a place id" do
      event.update_columns(location_latitude: nil, location_longitude: nil)
      expect(pass.additional_pass_keys[:directionsInformationURL]).to be_nil
    end

    it "links directions to the Apple Maps place" do
      event.update_columns(apple_place_id: "IMOCKPLACE")
      expect(pass.additional_pass_keys[:directionsInformationURL]).to eq("https://maps.apple.com/place?place-id=IMOCKPLACE")
    end
  end

  describe "#semantics" do
    it "tags the admission level when freedom waivers are on" do
      event.update!(freedom_waivers_enabled: true)
      expect(pass.semantics).to include(admissionLevel: "No Freedom Waiver", admissionLevelAbbreviation: "NO FW")
    end

    it "spells out a granted freedom waiver" do
      event.update!(freedom_waivers_enabled: true)
      allow(pass).to receive(:freedom_waiver_granted?).and_return(true)
      expect(pass.semantics).to include(admissionLevel: "Freedom Waiver", admissionLevelAbbreviation: "FW ✓")
    end

    it "leaves admission level off otherwise" do
      event.update!(freedom_waivers_enabled: false)
      expect(pass.semantics).not_to have_key(:admissionLevel)
    end
  end

  describe "generated pass.json" do
    it "carries the poster, featured action and relevantDates keys" do
      event.update_columns(apple_place_id: "IMOCKPLACE")
      record = Passkit::Pass.create!(klass: "Passkit::EventTicket", generator: participant_event,
                                     serial_number: SecureRandom.uuid, authentication_token: SecureRandom.hex(16))
      generator = Passkit::Generator.new(record)
      generator.instance_variable_set(:@temporary_path, Pathname.new(tmp_path))

      generator.send(:generate_json_pass)
      json = JSON.parse(File.read(File.join(tmp_path, "pass.json")))

      expect(json["preferredStyleSchemes"]).to eq(%w[posterEventTicket eventTicket])
      expect(json["featuredActions"].map { |a| a["type"] }).to eq(%w[place call])
      expect(json["featuredActions"].first["placeIdentifier"]).to eq("IMOCKPLACE")
      expect(json["relevantDates"]).to be_present
      expect(json["eventLogoText"]).to eq(event.name)
      expect(json["eventTicket"]).to include("primaryFields", "backFields")
    end
  end
end
