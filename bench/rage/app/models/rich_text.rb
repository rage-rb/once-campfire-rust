# frozen_string_literal: true

RichText = Class.new(ApplicationRecord)
class RichText
  set_dataset :action_text_rich_texts

  # Reference: ActionText::RichText at the pinned Rails revision. Keep Content's
  # canonicalization, storage and plain-text conversion without its AR model.
  def refresh
    @content = nil
    super
  end

  def body
    @content ||= ActionText::Content.new(self[:body]) if self[:body]
  end

  def body=(value)
    @content = value.is_a?(ActionText::Content) ? value : ActionText::Content.new(value) unless value.nil?
    @content = nil if value.nil?
    self[:body] = @content&.to_html
  end

  def to_plain_text = body&.to_plain_text.to_s
  def to_s = body.to_s
  def nil? = body.nil?
  def blank? = to_plain_text.blank?
  def empty? = to_plain_text.empty?
  def present? = to_plain_text.present?
end
