# The onboarding skin used to be one hardcoded look behind a series toggle
# (config.haven_onboarding). Branding is now data on the series (BrandTheme),
# so series that had the toggle on get the same look written out as their
# branding settings, and the toggle key goes.
#
# Data only, no schema change. It never raises: a failing migration
# crash-loops the pods on deploy, and the worst case here is a series that
# needs its branding re-entered in admin.
class MoveSeriesOnboardingSkinToBranding < ActiveRecord::Migration[8.1]
  class Series < ActiveRecord::Base
    self.table_name = "event_series"
  end

  SKIN_BRAND = {
    "background" => "#fff6d6",
    "ink" => "#4a2a12",
    "accent" => "#ed5615",
    "accent_fill" => "#b8430f",
    "secondary" => "#b8c220",
    "highlight" => "#fba71f",
    "card_from" => "#ffe382",
    "card_to" => "#fee0b1",
    "body_font" => "jua",
    "heading_font" => "darumadrop-one",
    "logo_image" => "brands/haven/haven-logo-color.webp",
    "mascot_image" => "brands/haven/hedgehog.webp",
    "footer_image" => "brands/haven/bottom-bushes.webp",
    "nav_style" => "progress",
    # The skin's hand-picked shades, pinned so it looks exactly as before.
    "tokens" => {
      "bg-elev-2" => "#fffaea",
      "bg-elev-3" => "#fff3cf",
      "bg-sunken" => "#f6e3ad",
      "text" => "#5b3a1e",
      "text-soft" => "#6e4a2a",
      "text-muted" => "#8a6440",
      "text-faint" => "#a88660",
      "border-soft" => "#fbefcc",
      "border" => "#f0dca6",
      "border-strong" => "#a67b45",
      "border-card" => "#ecd29a",
      "accent-fill-hover" => "#9a370b",
      "success-strong" => "#97a01a",
      "success-text" => "#5f6610",
      "done-fill" => "#6b7212"
    }
  }.freeze

  SKIN_NOTES = {
    "registration_note" => "Bring a laptop! You'll need one to build your project at the event.",
    "address_note" => "We ask for your address for safety reasons, and so we can ship prizes to attendees in the US.",
    "tshirt_note" => "Unisex, US sizing. You'll pick it up at the event."
  }.freeze

  def up
    Series.where("config ? 'haven_onboarding'").find_each do |series|
      config = series.config.dup
      flag = config.delete("haven_onboarding")
      if ActiveModel::Type::Boolean.new.cast(flag) && config["brand"].blank?
        config["brand"] = SKIN_BRAND
        SKIN_NOTES.each { |key, note| config[key] = note if config[key].blank? }
      end
      series.update_columns(config: config)
    rescue StandardError => e
      say "Skipped series #{series.id}: #{e.class}: #{e.message}"
    end
  end

  def down
    # Branding stays as data; there's no toggle to restore.
  end
end
