class Accommodation < ApplicationRecord
  has_paper_trail

  self.implicit_order_column = "created_at"

  # Deterministic so the Rails enum scopes (`gender_identity_male` etc.) and
  # WHERE-by-value lookups continue to work. Note: admin "sort by gender" now
  # sorts on ciphertext rather than label order — acceptable trade-off.
  encrypts :gender_identity, deterministic: true

  belongs_to :participant_event
  has_one :participant, through: :participant_event
  has_one :event, through: :participant_event

  GENDER_IDENTITIES = {
    female: "female",
    male: "male",
    non_binary: "non_binary",
    trans_female: "trans_female",
    trans_male: "trans_male",
    other: "other"
  }.freeze

  ROOMMATE_GENDER_OPTIONS = {
    female: "female",
    male: "male",
    non_binary: "non_binary",
    trans_female: "trans_female",
    trans_male: "trans_male",
    any: "any"
  }.freeze

  GENDER_BASE = {
    female: "Female",
    male: "Male",
    non_binary: "Non-binary"
  }.freeze

  enum :gender_identity, GENDER_IDENTITIES, prefix: true

  validates :participant_event_id, presence: true
  validate :validate_preferred_roommate_genders

  attr_accessor :gender_base, :is_transgender

  before_validation :convert_gender

  def preferred_roommate_genders=(values)
    super(Array(values).reject(&:blank?))
  end

  def gender_base
    return @gender_base if @gender_base.present?

    case gender_identity
    when "female", "trans_female" then "female"
    when "male", "trans_male" then "male"
    when "non_binary" then "non_binary"
    else nil
    end
  end

  def is_transgender
    return @is_transgender unless @is_transgender.nil?

    gender_identity.in?(%w[trans_female trans_male])
  end

  def gender_base=(value)
    @gender_base = value
  end

  def is_transgender=(value)
    @is_transgender = ActiveRecord::Type::Boolean.new.cast(value)
  end

  def gender_bucket
    case gender_identity
    when "male" then "male"
    when "female" then "female"
    when "trans_male", "trans_female", "non_binary", "other" then "nb_trans"
    else
      nil
    end
  end

  def trans_or_nb?
    gender_bucket == "nb_trans"
  end

  def allowed_roommate_gender_buckets
    return [ "male", "female", "nb_trans" ] if preferred_roommate_genders&.include?("any")
    return [ gender_bucket ].compact if preferred_roommate_genders.blank?

    preferred_roommate_genders.map do |pref|
      case pref
      when "male" then "male"
      when "female" then "female"
      when "trans_male", "trans_female", "non_binary" then "nb_trans"
      else nil
      end
    end.compact.uniq
  end

  def compatible_with?(other_accommodation)
    return false unless other_accommodation

    my_bucket = gender_bucket
    their_bucket = other_accommodation.gender_bucket

    return false if my_bucket.nil? || their_bucket.nil?

    their_bucket.in?(allowed_roommate_gender_buckets) &&
      my_bucket.in?(other_accommodation.allowed_roommate_gender_buckets)
  end

  private

  def convert_gender
    return if @gender_base.blank?

    case @gender_base
    when "female"
      self.gender_identity = @is_transgender ? "trans_female" : "female"
    when "male"
      self.gender_identity = @is_transgender ? "trans_male" : "male"
    when "non_binary"
      self.gender_identity = "non_binary"
    end
  end

  def nights_count
    return nil unless check_in_date && check_out_date

    (check_out_date - check_in_date).to_i
  end

  def assigned?
    assigned_room.present?
  end

  def requires_room?
    !rooming_exempt?
  end

  def validate_preferred_roommate_genders
    return if preferred_roommate_genders.blank?

    invalid = preferred_roommate_genders - ROOMMATE_GENDER_OPTIONS.values
    if invalid.any?
      errors.add(:preferred_roommate_genders, "contains invalid options: #{invalid.join(', ')}")
    end
  end
end
