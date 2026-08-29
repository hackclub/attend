# Rewrites phone attributes to E.164 before validation, so the database only
# ever holds one canonical format. Deterministic encryption means an equality
# lookup on `phone` never matches unless the stored format is canonical, so
# this also keeps ticket-to-participant matching and admin search working.
module NormalizesPhoneNumbers
  extend ActiveSupport::Concern

  class_methods do
    def normalizes_phone_number(*attributes, default_country: PhoneNormalizer::DEFAULT_COUNTRY)
      before_validation do
        attributes.each do |attribute|
          raw = public_send(attribute)
          next if raw.blank?

          normalized = PhoneNormalizer.normalize(raw, default_country: default_country)
          # Leave an unparseable value in place: the validator reports it back
          # to the person who typed it instead of silently blanking the field.
          public_send(:"#{attribute}=", normalized) if normalized
        end
      end
    end
  end
end
