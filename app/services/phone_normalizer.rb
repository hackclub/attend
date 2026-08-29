# Single source of truth for turning a user- or import-supplied phone number
# into E.164. Every phone number entering the app should pass through here.
#
# The important rule is that a number must be *valid*, not merely *possible*.
# Phonelib's `possible?` is only a length check, so "15555555", "0555550100"
# and "+1 0555550100" all pass it while being undialable — which is exactly
# how those numbers ended up in the database.
class PhoneNormalizer
  # A number typed without a country code is interpreted against this country.
  # A national-format number from anywhere else overwhelmingly fails `valid?`
  # and is rejected, rather than silently becoming a bogus US number.
  DEFAULT_COUNTRY = "US"

  # Strips the channel prefixes Twilio puts on inbound addresses.
  CHANNEL_PREFIX = /\A(?:whatsapp|sms|tel|messenger):/i

  class << self
    # The E.164 string, or nil when the input is not a real dialable number.
    # Never returns the raw input — a caller that falls back to the raw string
    # is how unparseable junk gets persisted.
    def normalize(raw, default_country: DEFAULT_COUNTRY)
      parsed = parse(raw, default_country: default_country)
      return nil unless parsed&.valid?

      parsed.e164
    end

    def valid?(raw, default_country: DEFAULT_COUNTRY)
      normalize(raw, default_country: default_country).present?
    end

    # The number as its own country writes it, for display only.
    def national(raw, default_country: DEFAULT_COUNTRY)
      parsed = parse(raw, default_country: default_country)
      return raw.to_s if parsed.nil? || !parsed.valid?

      parsed.national
    end

    # Two-letter country of the number, or nil if it doesn't resolve.
    def country(raw, default_country: DEFAULT_COUNTRY)
      parsed = parse(raw, default_country: default_country)
      parsed&.valid? ? parsed.country : nil
    end

    def parse(raw, default_country: DEFAULT_COUNTRY)
      cleaned = clean(raw)
      return nil if cleaned.blank?

      # An explicit country code always wins over the default, or "+44 7911
      # 123456" gets re-read against DEFAULT_COUNTRY and comes out wrong.
      return Phonelib.parse(cleaned, nil) if cleaned.start_with?("+")

      # No country code and nothing to assume: refuse to guess.
      return nil if default_country.blank?

      Phonelib.parse(cleaned, default_country)
    end

    private

    def clean(raw)
      str = raw.to_s.strip
      return "" if str.blank?

      str = str.sub(CHANNEL_PREFIX, "").strip
      # "00" is the international access prefix across most of the world;
      # Phonelib only understands the "+" form.
      str = str.sub(/\A00(?=\d)/, "+")
      # A lone "+" or a string with no digits at all is never a number.
      return "" unless str.match?(/\d/)

      str
    end
  end
end
