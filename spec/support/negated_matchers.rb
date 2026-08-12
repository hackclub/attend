# RSpec has no built-in negated `change`, and `expect { }.not_to change` can't be
# composed with `.and`. Defining it lets a single block assert several things did
# not change: `.to not_change(Participant, :count).and not_change(Foo, :count)`.
RSpec::Matchers.define_negated_matcher :not_change, :change
