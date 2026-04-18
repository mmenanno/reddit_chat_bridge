# frozen_string_literal: true

module Matrix
  # Tiny helpers for Matrix identifier parsing. Matrix user ids are shaped
  # like `@t2_abc123:reddit.com`; the "localpart" is `t2_abc123` — the stable
  # Reddit account id that we use in Discord channel slugs and display
  # fallbacks when a human username hasn't been resolved yet.
  module Id
    USER_SIGIL = /\A@/
    HOMESERVER_SUFFIX = /:.+\z/

    class << self
      def localpart(matrix_id)
        matrix_id.to_s.sub(USER_SIGIL, "").sub(HOMESERVER_SUFFIX, "")
      end
    end
  end
end
