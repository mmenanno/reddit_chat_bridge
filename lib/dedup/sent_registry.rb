# frozen_string_literal: true

module Dedup
  # Maps Matrix event_ids we sent (Discord → Reddit) so the /sync echo
  # of the same event can be skipped inside the Poster. Thin wrapper
  # over OutboundMessage so all the persistence lives there.
  #
  # Exists as a named class on purpose — the Poster only has to care
  # about "is this event echo?", not about OutboundMessage's schema.
  class SentRegistry
    def initialize(model: OutboundMessage)
      @model = model
    end

    def sent_by_us?(matrix_event_id)
      @model.posted_event?(matrix_event_id)
    end
  end
end
