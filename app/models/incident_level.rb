# The one incident scale used everywhere: an event incident's severity, a
# report to HQ's priority, badges, Slack posts, mail subjects and the docs.
# Matches HQ's triage chart (docs/organizers/reporting-incidents.mdx).
module IncidentLevel
  Level = Struct.new(:key, :name, :target, :examples, :color, :console_severity, keyword_init: true) do
    def code = key.upcase
    def label = "#{code} · #{name} · #{target}"
    def short_label = "#{code} · #{name}"
  end

  LEVELS = [
    Level.new(key: "s0", name: "High priority", target: "≈ 5 minutes", color: "red", console_severity: "critical",
      examples: [ "Medical emergencies", "Fire", "Evacuation", "Missing participant", "Organiser misconduct" ]),
    Level.new(key: "s1", name: "Moderate priority", target: "≈ 1 hour", color: "amber", console_severity: "high",
      examples: [ "Racial discrimination", "Misogynistic behaviour / sexual harassment", "Homophobia / transphobia",
                  "Disclosure of a safeguarding incident", "Participant-on-participant violence" ]),
    Level.new(key: "s2", name: "Low priority", target: "≈ 12 hours", color: "green", console_severity: "medium",
      examples: [ "Disagreements between participants", "Microaggressions" ]),
    Level.new(key: "s3", name: "Follow-up", target: "After the event", color: "blue", console_severity: "low",
      examples: [ "Hack Club may follow up after the event to complete the log and check that the incident was handled correctly." ])
  ].freeze

  BY_KEY = LEVELS.index_by(&:key).freeze
  KEYS = BY_KEY.keys.freeze
  ENUM = KEYS.index_by(&:to_sym).freeze
  LABELS = LEVELS.to_h { |l| [ l.key, l.label ] }.freeze

  # The level that pages HQ by phone and is forced when emergency services
  # were called.
  EMERGENCY = "s0".freeze
  # Where an emergency lands when the event is too old to page for.
  EMERGENCY_FALLBACK = "s1".freeze
  # What a form offers before anyone picks.
  DEFAULT = "s2".freeze

  def self.find(key) = BY_KEY[key.to_s]
  def self.label(key) = find(key)&.label || key.to_s.humanize
  def self.code(key) = find(key)&.code || key.to_s.humanize
  def self.select_options = LEVELS.map { |l| [ l.label, l.key ] }
end
