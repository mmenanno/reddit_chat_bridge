# frozen_string_literal: true

# Abstract base for every ActiveRecord model in the bridge. Keeps the
# inheritance chain visible and gives us one place to hang shared concerns
# when we need them.
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end
