# frozen_string_literal: true

module Discord
  # Shared embed color palette. Reused by every component that returns
  # an embed (slash commands, message-request notifier) so the bridge
  # presents a single visual identity in Discord regardless of where
  # the message originated.
  module Colors
    EMBER = 0xE8_5D_20    # primary accent — informational embeds
    MOSS  = 0x4A_A5_3B    # success — green
    RUST  = 0xB8_45_2A    # error — red-orange
    AMBER = 0xE8_AB_20    # warning — yellow that lives in the same warm family as EMBER/RUST
    SLATE = 0x4A_5C_6E    # diagnostic / muted neutral — e.g. /room detail dump
  end
end
