# Match reference/config/puma.rb: a new server cannot inherit live connections
# from a previous process. Run once in the master before workers are forked.
Iodine.on_state(:pre_start) do
  Membership.disconnect_all
  # Workers must open their own SQLite handles after fork.
  CampfireBenchmark::DB.disconnect
end
