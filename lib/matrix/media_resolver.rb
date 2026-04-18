# frozen_string_literal: true

module Matrix
  # Turns a Matrix `mxc://<server>/<media_id>` URL into an https link the
  # Discord client (and the human on the other side) can actually render.
  #
  # Reddit's media server is the same origin as its homeserver, so the
  # download endpoint is just /_matrix/media/v3/download/<server>/<id>.
  # Authorization is not required for media reads on Reddit's server.
  class MediaResolver
    MXC_PATTERN = %r{\Amxc://([^/]+)/([^/?#]+)\z}

    def initialize(homeserver:)
      @homeserver = homeserver.to_s.delete_suffix("/")
    end

    def resolve(mxc_url)
      match = MXC_PATTERN.match(mxc_url.to_s)
      return unless match

      server = match[1]
      media_id = match[2]
      "#{@homeserver}/_matrix/media/v3/download/#{server}/#{media_id}"
    end
  end
end
