# frozen_string_literal: true

# Keep Lexxy's content sanitizer configuration without loading its AR/Storage
# engine. These options come from the pinned lexxy/engine.rb initializer.
ActiveSupport.on_load(:action_text_content) do
  defaults = Class.new.include(ActionText::ContentHelper).new
  ActionText::ContentHelper.allowed_tags = defaults.sanitizer_allowed_tags + %w[video audio source embed table tbody tr th td]
  ActionText::ContentHelper.allowed_attributes = defaults.sanitizer_allowed_attributes + %w[controls poster data-language style value start]
  Loofah::HTML5::SafeList::ALLOWED_CSS_FUNCTIONS << "var"
end

module BenchmarkActionText
  # Action Text's content API hardcodes AR's missing-record exception. Substitute
  # Sequel's exception at this boundary, preserving signed User mentions.
  module Attachables
    def from_attachable_sgid(sgid, options = {})
      options = options.merge(only: [options[:only]]) if options[:only].is_a?(Module)
      method = sgid.is_a?(Array) ? :locate_many_signed : :locate_signed
      GlobalID::Locator.public_send(method, sgid, options.merge(for: ActionText::Attachable::LOCATOR_NAME)) || raise(Sequel::NoMatchingRow)
    end

    private
      def attachable_from_sgid(sgid)
        from_attachable_sgid(sgid)
      rescue Sequel::NoMatchingRow
        nil
      end
  end

  # Reference: reference/lib/rails_ext/action_text_attachables.rb. Keep the
  # historical User-only fallback after a secret rotation, without AR exceptions.
  module Attachments
    private
      def attachable_from_possibly_expired_sgid(sgid)
        return unless message = sgid&.split("--")&.first
        encoded = JSON.parse(decode_base64(message))
        gid = if data = encoded.dig("_rails", "data")
          data
        elsif data = encoded.dig("_rails", "message")
          decode_base64(data).match(%r{(gid://campfire/[^/]+/\d+)})&.to_s
        end
        if model = GlobalID.find(gid)
          model if model.model_name.to_s == "User"
        end
      rescue Sequel::NoMatchingRow
        nil
      end
  end
end
