require "rails_helper"

RSpec.describe BrandTheme do
  let(:warm) { { "background" => "#fff6d6", "ink" => "#4a2a12", "accent" => "#ed5615" } }

  describe "#active?" do
    it "needs the background, text and accent colours" do
      expect(described_class.new({})).not_to be_active
      expect(described_class.new(warm.except("accent"))).not_to be_active
      expect(described_class.new(warm)).to be_active
    end
  end

  describe "#resolved_tokens" do
    it "works out every token that carries text, fills or outlines so it passes contrast" do
      tokens = described_class.new(warm.merge("secondary" => "#b8c220")).resolved_tokens

      BrandTheme::TEXT_TOKENS.each do |token|
        %w[bg-app bg-elev].each do |surface|
          expect(described_class.contrast(tokens[token], tokens[surface])).to be >= 4.5, "#{token} on #{surface}"
        end
      end
      BrandTheme::FILL_TOKENS.each do |token|
        expect(described_class.contrast("#ffffff", tokens[token])).to be >= 4.5, "white on #{token}"
      end
      %w[border-strong focus-ring].each do |token|
        expect(described_class.contrast(tokens[token], tokens["bg-elev"])).to be >= 3.0, token
      end
    end

    it "darkens an accent too light for white button text" do
      tokens = described_class.new(warm.merge("accent" => "#ffd059")).resolved_tokens

      expect(tokens["accent"]).to eq("#ffd059")
      expect(described_class.contrast("#ffffff", tokens["accent-fill"])).to be >= 4.5
    end

    it "lets exact values be pinned" do
      theme = described_class.new(warm.merge("tokens" => "--text-muted: #8a6440\nborder: #F0DCA6"))

      expect(theme.resolved_tokens["text-muted"]).to eq("#8a6440")
      expect(theme.resolved_tokens["border"]).to eq("#f0dca6")
    end

    it "leaves the theme's success colours alone without a secondary colour" do
      tokens = described_class.new(warm).resolved_tokens

      expect(tokens).not_to have_key("success-text")
      expect(tokens["done-fill"]).to eq(tokens["accent-fill"])
    end
  end

  describe "validation" do
    it "accepts a brand that meets every floor" do
      expect(described_class.new(warm)).to be_valid
    end

    it "rejects text that can't be read on the background, with the ratio" do
      theme = described_class.new("background" => "#ffffff", "ink" => "#cccccc", "accent" => "#ed5615")

      expect(theme).not_to be_valid
      expect(theme.errors[:base]).to include(a_string_matching(/Text colour on the page background is 1\.6\d?:1, below the 4\.5:1 minimum/))
    end

    it "rejects a pinned token that breaks contrast" do
      theme = described_class.new(warm.merge("tokens" => { "text-muted" => "#e0d0b0" }))

      expect(theme).not_to be_valid
      expect(theme.errors[:base].join).to include("Hint text on the page background")
    end

    it "rejects unknown tokens, bad colours, fonts and images" do
      theme = described_class.new(warm.merge(
        "card_from" => "orange",
        "body_font" => "comic-sans",
        "logo_image" => "../../config/master.key",
        "nav_style" => "sideways",
        "tokens" => "glitter: #ffffff"
      ))

      expect(theme).not_to be_valid
      expect(theme.errors.attribute_names).to include(:card_from, :body_font, :logo_image, :nav_style, :tokens)
    end

    it "needs the required colours once any colour is set" do
      theme = described_class.new("accent" => "#ed5615")

      expect(theme).not_to be_valid
      expect(theme.errors.attribute_names).to include(:background, :ink)
    end

    it "only offers images under the brands folder" do
      expect(described_class.image_options).to include("brands/haven/hedgehog.webp")
      expect(described_class.image_options).to all(start_with("brands/"))
    end
  end

  describe ".normalize" do
    it "drops blanks, lowercases colours and parses the token text" do
      expect(described_class.normalize("background" => " #FFF6D6 ", "ink" => "", "tokens" => "--text: #5B3A1E\n\n", "rogue" => "x"))
        .to eq("background" => "#fff6d6", "tokens" => { "text" => "#5b3a1e" })
    end
  end
end
