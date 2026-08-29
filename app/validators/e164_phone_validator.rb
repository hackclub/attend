# Requires a real, dialable phone number.
#
# Named to avoid colliding with the `PhoneValidator` phonelib registers for
# `validates :phone, phone: true`. That one was previously used here as
# `phone: { possible: true }`, which only length-checks and let undialable
# numbers through.
#
# Pair with `normalizes_phone_number` so the attribute is already E.164 by the
# time this runs; anything still failing here is genuinely unparseable.
class E164PhoneValidator < ActiveModel::EachValidator
  MESSAGE = "is not a valid phone number. Include the country code, " \
            "for example +1 415 555 0132.".freeze

  def validate_each(record, attribute, value)
    return if value.blank?
    return if PhoneNormalizer.valid?(value, default_country: default_country)

    record.errors.add(attribute, options[:message] || MESSAGE)
  end

  private

  # `default_country: nil` makes the attribute strict E.164 — a number with no
  # country code is rejected instead of being read as a US number.
  def default_country
    options.fetch(:default_country, PhoneNormalizer::DEFAULT_COUNTRY)
  end
end
