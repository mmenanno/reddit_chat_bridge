# frozen_string_literal: true

require "ed25519"

module Discord
  # Verifies the Ed25519 signature Discord attaches to every HTTP
  # interaction request. Discord rejects any endpoint that doesn't
  # reject invalid signatures, so this check is load-bearing.
  #
  # Spec: https://discord.com/developers/docs/interactions/receiving-and-responding#security-and-authorization
  class InteractionVerifier
    def initialize(public_key_hex:)
      @public_key_hex = public_key_hex.to_s
    end

    # `signature_hex` and `timestamp` come from the request headers
    # `X-Signature-Ed25519` and `X-Signature-Timestamp`. `body` is the
    # *raw* request body — not a parsed hash — since Discord signs the
    # exact bytes they sent.
    def valid?(signature_hex:, timestamp:, body:)
      return false if @public_key_hex.empty?
      return false if signature_hex.to_s.empty? || timestamp.to_s.empty?

      key = Ed25519::VerifyKey.new([@public_key_hex].pack("H*"))
      signature = [signature_hex].pack("H*")
      key.verify(signature, "#{timestamp}#{body}")
    rescue Ed25519::VerifyError, ArgumentError, TypeError
      false
    end
  end
end
