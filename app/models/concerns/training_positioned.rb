# Ordering for course content: courses, lessons, questions, and options all
# sit in an author-chosen order among their siblings. New rows go to the end,
# and move! swaps a row with its neighbour.
module TrainingPositioned
  extend ActiveSupport::Concern

  included do
    scope :ordered, -> { order(:position, :created_at) }
    before_create :append_position, unless: -> { position.to_i.positive? }
  end

  def move!(direction)
    neighbours = siblings.ordered.to_a
    index = neighbours.index(self)
    other = neighbours[direction.to_s == "up" ? index - 1 : index + 1] if index
    return false if other.nil? || (direction.to_s == "up" && index.zero?)

    transaction do
      neighbours.each_with_index { |row, i| row.update_column(:position, i + 1) if row.position != i + 1 }
      mine = neighbours.index(self) + 1
      theirs = neighbours.index(other) + 1
      update_column(:position, theirs)
      other.update_column(:position, mine)
    end
    true
  end

  private

  def append_position
    self.position = (siblings.maximum(:position) || 0) + 1
  end
end
