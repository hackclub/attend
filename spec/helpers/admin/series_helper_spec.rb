require "rails_helper"

RSpec.describe Admin::SeriesHelper, type: :helper do
  def stage_rows(*percents)
    percents.map { |p| { percent: p, stage: nil, stalled: 0 } }
  end

  describe "#series_funnel_ribbon" do
    it "returns nothing when there are no stages to draw" do
      expect(helper.series_funnel_ribbon([])).to be_nil
    end

    it "opens at the full band and closes the path" do
      ribbon = helper.series_funnel_ribbon(stage_rows(100, 50))

      expect(ribbon[:segments]).to eq(2)
      # y=0 is the top of the 180-unit viewBox: the whole active population.
      expect(ribbon[:path]).to start_with("M 0 0 ")
      expect(ribbon[:path]).to end_with("Z")
    end

    it "mirrors the bottom edge about the centre line" do
      path = helper.series_funnel_ribbon(stage_rows(100, 60, 20))[:path]
      ys = path.scan(/[\d.]+ ([\d.]+)/).flatten.map(&:to_f)

      # Every y has a partner at 180 - y, so the ribbon is symmetric about y=90.
      ys.each { |y| expect(ys).to include(a_value_within(0.02).of(180 - y)) }
    end

    it "narrows monotonically, never widening at a later stage" do
      path = helper.series_funnel_ribbon(stage_rows(100, 88, 71, 71, 42))[:path]
      # Top-edge anchor points, in order: y grows as the band closes in.
      tops = path.scan(/C [\d.]+ [\d.]+, [\d.]+ [\d.]+, [\d.]+ ([\d.]+)/)
        .flatten.map(&:to_f).take_while { |y| y <= 90 }

      expect(tops).to eq(tops.sort)
      expect(tops.last).to be_within(0.1).of(90 - 0.42 * 90)
    end

    it "survives a single stage and a stage that empties completely" do
      expect(helper.series_funnel_ribbon(stage_rows(100))[:segments]).to eq(1)

      pinched = helper.series_funnel_ribbon(stage_rows(100, 0))[:path]
      # A stage nobody clears pinches the ribbon shut on the centre line rather
      # than producing a NaN or an inverted shape.
      expect(pinched).to include("1000 90")
      expect(pinched).not_to match(/NaN|-\d/)
    end
  end

  describe "#series_blocked_fill" do
    # Asserted as properties, not hexes: the ramp is re-stepped whenever its
    # contrast against OSM tiles is re-measured, and a test that pins the hex
    # only ever reports that someone changed the hex on purpose.
    def luminance(hex)
      channels = hex.delete("#").scan(/../).map do |pair|
        c = pair.to_i(16) / 255.0
        c <= 0.03928 ? c / 12.92 : (((c + 0.055) / 1.055)**2.4)
      end
      0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    end

    it "offers one distinct step per band" do
      fills = [ 0.0, 0.1, 0.25, 0.45, 0.65 ].map { |share| helper.series_blocked_fill(share) }

      expect(fills.length).to eq(5)
      expect(fills.uniq.length).to eq(5)
    end

    it "deepens monotonically as the share of blocked participants rises" do
      shares = [ 0.0, 0.05, 0.1, 0.2, 0.25, 0.4, 0.45, 0.6, 0.65, 0.9, 1.0 ]
      luminances = shares.map { |share| luminance(helper.series_blocked_fill(share)) }

      # Never lighter than the step before it, and the ends actually differ, so
      # a ramp that collapsed to one colour would fail rather than pass.
      expect(luminances).to eq(luminances.sort.reverse)
      expect(luminances.first).to be > luminances.last
    end

    it "opens on the lightest step and never returns anything lighter" do
      lightest = luminance(helper.series_blocked_fill(0.0))
      others = [ 0.1, 0.25, 0.45, 0.65, 1.0 ].map { |s| luminance(helper.series_blocked_fill(s)) }

      expect(others).to all(be < lightest)
    end

    it "clamps a share below the first band to the lightest step" do
      expect(helper.series_blocked_fill(-0.5)).to eq(helper.series_blocked_fill(0.0))
    end
  end
end
