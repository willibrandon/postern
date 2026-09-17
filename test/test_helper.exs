Application.put_env(:gen_lsp, :exit_on_end, false)

# The live tests write into a server's data directory, so they run only when
# PGHOST names one, as CI does for every supported version. Without it the
# suite is offline, and the other libpq variables a shell or a CI image
# carries, as GitHub's Windows runners do with PGUSER and PGPASSWORD, are
# cleared so that they cannot turn the live connection on in the server
# tests and make them report a server that is not there.
excludes = if match?({:win32, _}, :os.type()), do: [:unix], else: []

excludes =
  if System.get_env("PGHOST") do
    excludes
  else
    Enum.each(~w(PGPORT PGDATABASE PGUSER PGPASSWORD), &System.delete_env/1)
    [:live | excludes]
  end

ExUnit.start(exclude: excludes)
ExUnit.configure(assert_receive_timeout: 2000, refute_receive_timeout: 2000)
