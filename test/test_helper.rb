ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# No `parallelize` and no `fixtures :all`: every test here is non-transactional, builds its own
# data and cleans up manually (Orders then Products), and all tests share one test database,
# so parallel workers would corrupt each other. The scaffold fixtures were deleted.
