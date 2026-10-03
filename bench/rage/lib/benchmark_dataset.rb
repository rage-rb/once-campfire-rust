module BenchmarkDataset
  def self.validate!
    # Match fill.py's first-run dataset, including names rendered into every frame.
    # Reject unsupported data before Deferred can silently retry real push jobs.
    check(Account.count == 1 && Account.first.name == FirstRun::ACCOUNT_NAME, "one Campfire account")
    check(User.count == 1, "one user (no bots)")
    user = User.first
    check(user.id == 1 && user.active? && user.administrator? && user.name == "David Hansson" &&
      user.email_address == "david@example.com" && user.authenticate("secret123456"), "the fill.py administrator")
    check(Room.count == 1, "one room")
    room = Room.first
    check(room.id == 1 && room.open? && room.name == FirstRun::FIRST_ROOM_NAME && room.creator_id == user.id, "the first-run All Talk room (id 1)")
    check(Membership.count == 1 && room.memberships.exists?(user: user, involvement: :mentions), "one first-run membership")
    check(Push::Subscription.none?, "no push subscriptions")
    true
  end

  def self.check(condition, expectation)
    raise ArgumentError, "Invalid benchmark dataset: expected #{expectation}; use an isolated, freshly prepared WORK" unless condition
  end
  private_class_method :check
end
