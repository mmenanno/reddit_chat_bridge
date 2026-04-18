# frozen_string_literal: true

require "test_helper"
require "discord/interaction_verifier"

module Discord
  class InteractionVerifierTest < ActiveSupport::TestCase
    SIGNING_KEY = Ed25519::SigningKey.generate
    VERIFY_KEY  = SIGNING_KEY.verify_key
    PUBLIC_KEY_HEX = VERIFY_KEY.to_bytes.unpack1("H*")

    test "accepts a signature produced by the matching private key" do
      verifier = InteractionVerifier.new(public_key_hex: PUBLIC_KEY_HEX)
      body = '{"type":1}'
      ts = "1711111111"
      sig = SIGNING_KEY.sign("#{ts}#{body}").unpack1("H*")

      assert(verifier.valid?(signature_hex: sig, timestamp: ts, body: body))
    end

    test "rejects a tampered body" do
      verifier = InteractionVerifier.new(public_key_hex: PUBLIC_KEY_HEX)
      ts = "1711111111"
      sig = SIGNING_KEY.sign("#{ts}ORIGINAL").unpack1("H*")

      refute(verifier.valid?(signature_hex: sig, timestamp: ts, body: "TAMPERED"))
    end

    test "rejects when the public key is empty" do
      verifier = InteractionVerifier.new(public_key_hex: "")

      refute(verifier.valid?(signature_hex: "abcd", timestamp: "1", body: "x"))
    end

    test "rejects when the signature is malformed" do
      verifier = InteractionVerifier.new(public_key_hex: PUBLIC_KEY_HEX)

      refute(verifier.valid?(signature_hex: "not-hex", timestamp: "1", body: "x"))
    end
  end
end
