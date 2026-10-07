# frozen_string_literal: true

class Message < ApplicationRecord
  many_to_one :room
  many_to_one :creator, class: :User
  one_to_many :boosts
  include BenchmarkMessageRendering::Broadcasts

  dataset_module do
    def ordered = order(:created_at)
    def search(query)
      join(:message_search_index, rowid: Sequel[:messages][:id]).where(Sequel.lit("message_search_index.body MATCH ?", query)).select_all(:messages).ordered
    end
  end

  def before_validation
    self.creator ||= Current.user
    super
  end

  def before_create
    self.client_message_id ||= Random.uuid
    super
  end

  # Persist the parent, rich text and room touch in the same Sequel transaction.
  # Reference: reference/app/models/message.rb and ActionText::RichText.
  def after_save
    super
    if @rich_text
      @rich_text.set(record_type: "Message", record_id: id, name: "body").save
    end
    room.touch
  end

  def after_create
    super
    db.after_commit do
      db[:message_search_index].insert(rowid: id, body: plain_text_body)
      room.receive(self)
    end
  end

  def after_update
    super
    db.after_commit { db[:message_search_index].where(rowid: id).update(body: plain_text_body) }
  end

  def before_destroy
    boosts_dataset.each(&:destroy)
    RichText.where(record_type: "Message", record_id: id).each(&:destroy)
    super
  end

  def after_destroy
    super
    room.touch
    db.after_commit { db[:message_search_index].where(rowid: id).delete }
  end

  def refresh
    @rich_text = nil
    super
  end

  def body
    @rich_text ||= Queries::RichText.fetch_for_message(message_id: id) || RichText.new(name: "body", record_type: "Message")
  end

  def body=(value)
    body.body = value
    modified!
  end

  def boosts = boosts_dataset
  def plain_text_body = body.to_plain_text.presence || ""
  def to_key = [client_message_id]
  def content_type = (sound.present? ? "sound" : "text").inquiry

  def sound
    plain_text_body.match(/\A\/play (?<name>\w+)\z/) { |match| Sound.find_by_name(match[:name]) }
  end

  def mentionees
    users = body.body ? body.body.attachables.grep(User).uniq : []
    room.users_dataset.where(Sequel[:users][:id] => users.map(&:id))
  end

  # Uploads are outside this slice (and rejected by its controller). Keep the
  # attachment processing call in the text path used by the reference.
  def process_attachment = nil
  def attachment? = false
end
