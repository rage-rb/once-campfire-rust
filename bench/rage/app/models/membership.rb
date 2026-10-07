# frozen_string_literal: true

class Membership < ApplicationRecord
  CONNECTION_TTL = 60.seconds
  many_to_one :room
  many_to_one :user

  dataset_module do
    def visible = exclude(involvement: "invisible")
    def unread = exclude(unread_at: nil)
    def connected = where { connected_at >= Membership::CONNECTION_TTL.ago }
    def disconnected
      where(Sequel.|({ connected_at: nil }, Sequel[:connected_at] < Membership::CONNECTION_TTL.ago))
    end
  end

  def self.disconnect_all
    connected.update(connected_at: nil, connections: 0, updated_at: Time.current)
  end

  def self.grant(room, users, involvement: room.default_involvement)
    now = Time.current
    rows = Array(users).map { |user| { room_id: room.id, user_id: user.id, involvement: involvement, created_at: now, updated_at: now } }
    dataset.insert_conflict.multi_insert(rows) unless rows.empty?
  end

  # Reference: reference/app/models/membership/connectable.rb. The synchronous
  # path keeps its timestamp and arithmetic behavior; batching lives separately.
  def connected? = !connected_at.nil? && connected_at >= CONNECTION_TTL.ago
  def unread? = unread_at.present?
  def read = update(unread_at: nil)

  def present
    model.where(id: id).update(connections: connected? ? connections + 1 : 1, connected_at: Time.current, unread_at: nil)
  end

  def connected
    increment_connections
    touch(:connected_at)
  end

  def disconnected
    decrement_connections
    update(connected_at: nil) if connections < 1
  end

  def refresh_connection
    increment_connections unless connected?
    touch(:connected_at)
  end

  def increment_connections
    change_connections(1)
  end

  def decrement_connections
    change_connections(-1)
  end

  private
    def change_connections(delta)
      if connected?
        self.connections += delta
        self.updated_at = Time.current
        model.where(id: id).update(connections: Sequel[:connections] + delta, updated_at: updated_at)
      else
        update(connections: delta.positive? ? 1 : 0)
      end
    end
end
