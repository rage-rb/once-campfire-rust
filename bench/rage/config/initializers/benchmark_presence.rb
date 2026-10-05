# Match reference/config/puma.rb: a new server cannot inherit live connections
# from a previous process. Run once in the master before workers are forked.
Iodine.on_state(:pre_start) { Membership.disconnect_all }
