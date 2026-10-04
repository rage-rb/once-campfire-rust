# frozen_string_literal: true

require "zlib"

module BenchmarkCableCompression
  def serialize(params, data)
    json = super
    return json if json.bytesize < 256

    # Match crates/cable/src/socket.rs: level 6, raw deflate, a fresh stream per
    # message and sync flush without its trailer. Serialize before Iodine fan-out.
    compressor = Zlib::Deflate.new(6, -Zlib::MAX_WBITS)
    payload = compressor.deflate(json, Zlib::SYNC_FLUSH)
    # Iodine selects text frames from the encoding; these benchmark bytes are
    # decoded by loadgen's --deflate mode rather than a browser WebSocket client.
    payload.byteslice(0, payload.bytesize - 4).force_encoding(Encoding::UTF_8)
  ensure
    compressor&.close
  end
end
