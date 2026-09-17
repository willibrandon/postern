Application.put_env(:gen_lsp, :exit_on_end, false)

# The live tests write into a server's data directory, so they run only when
# PGHOST names one, as CI does for every supported version.
excludes = if match?({:win32, _}, :os.type()), do: [:unix], else: []
excludes = if System.get_env("PGHOST"), do: excludes, else: [:live | excludes]

ExUnit.start(exclude: excludes)
ExUnit.configure(assert_receive_timeout: 2000, refute_receive_timeout: 2000)
