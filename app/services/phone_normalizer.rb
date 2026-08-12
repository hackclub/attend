class PhoneNormalizer
  def self.normalize(raw)
    return nil if raw.blank?

    stripped = raw.sub(/\Awhatsapp:/, "")
    parsed = if stripped.start_with?("+")
               Phonelib.parse(stripped)
    else
               Phonelib.parse(stripped, nil)
    end

    parsed.valid? ? parsed.e164 : nil
  end
end
