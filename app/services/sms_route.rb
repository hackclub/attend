# Which sender an SMS to a given number goes out from, if any.
#
# Our US number delivers well inside +1 and to a handful of other countries,
# and fails in most of the rest (carriers reject it or Twilio blocks it), so
# outside those we either use the "Hack Club" alphanumeric sender where a
# country accepts one without registration, or don't text at all and rely on
# WhatsApp and email. Measured from a week of prod traffic (Nov 2026):
# US/CA 96% delivered, IN/CO/AU/NZ over 90%, GB/AE/PH/MY/PK 0%.
#
# Alphanumeric senders are one-way: people can't reply, and Twilio's STOP
# handling doesn't apply to them.
#
# Adding a country: put it in ALPHA_COUNTRIES once a test send from
# "Hack Club" arrives, or once its sender ID registration is approved in the
# Twilio console (AE, PH, ID, QA need one; see Twilio's per-country guidelines).
class SmsRoute
  ALPHA_SENDER = "Hack Club".freeze

  LONG_CODE_COUNTRIES = %w[IN CO AU NZ].freeze
  ALPHA_COUNTRIES = %w[GB].freeze

  # Returns the From value for an SMS to `phone`, or nil when we don't text
  # that country. Every +1 number (the US, Canada and the rest of the
  # North American plan) goes from our long code.
  def self.sender_for(phone, long_code:)
    phone = phone.to_s
    return long_code if phone.start_with?("+1")

    # A number can belong to several countries that share a code (+44 is
    # the UK, Guernsey, Jersey and the Isle of Man), so match on any of them.
    countries = Phonelib.parse(phone).countries
    return long_code if countries.intersect?(LONG_CODE_COUNTRIES)
    return ALPHA_SENDER if countries.intersect?(ALPHA_COUNTRIES)

    nil
  end

  # Countries staff are told we can't text, by name, for the message form.
  # Any country outside the two lists above gets no SMS either; these are the
  # ones our events actually run in, so they're the ones worth naming.
  NO_SMS_COUNTRIES = {
    "AE" => "the United Arab Emirates",
    "EG" => "Egypt",
    "HK" => "Hong Kong",
    "ID" => "Indonesia",
    "MN" => "Mongolia",
    "MX" => "Mexico",
    "MY" => "Malaysia",
    "NI" => "Nicaragua",
    "PH" => "the Philippines",
    "PK" => "Pakistan",
    "QA" => "Qatar",
    "RO" => "Romania",
    "UZ" => "Uzbekistan"
  }.freeze

  # Other ways events write these countries in their free-text location.
  COUNTRY_ALIASES = {
    "uae" => "AE", "emirates" => "AE", "united arab emirates" => "AE",
    "philippines" => "PH", "republic of the philippines" => "PH",
    "hong kong sar" => "HK"
  }.freeze

  def self.sms_available?(phone, long_code: "+1")
    sender_for(phone, long_code:).present?
  end

  # The country code a number we can't text belongs to, or nil if we can
  # text it (or can't tell where it is).
  def self.no_sms_country_for(phone)
    return if phone.blank? || sms_available?(phone)

    Phonelib.parse(phone).country
  end

  def self.country_name(code)
    NO_SMS_COUNTRIES[code] || code
  end

  # The no-SMS country an event's free-text location_country names, if any:
  # "Uzbekistan", "UZ" and "UAE" all resolve.
  def self.no_sms_country_named(name)
    key = name.to_s.strip.downcase.delete_prefix("the ")
    return if key.empty?

    code = COUNTRY_ALIASES[key] ||
      NO_SMS_COUNTRIES.find { |iso, label| iso.downcase == key || label.downcase.delete_prefix("the ") == key }&.first
    code if NO_SMS_COUNTRIES.key?(code)
  end
end
