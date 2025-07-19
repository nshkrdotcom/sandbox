[
  # False positive: The condition function in wait_for_compilation can return false
  # when Sandbox.Manager.get_sandbox_info returns {:error, _}
  {"lib/sandbox/test/helpers.ex", :pattern_match, 1}
]