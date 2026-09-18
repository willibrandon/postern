defmodule Postern.Stdio do
  @moduledoc """
  The stdio transport, with one difference from GenLSP's own: when the editor
  is gone, the VM halts at once.

  GenLSP calls `System.stop/0` on end of file, which is a graceful shutdown.
  Under Burrito the application never finishes starting (see
  `Postern.Application`), so that shutdown cannot complete, and an editor that
  closes the pipe in the same instant it sends `exit` can leave the process
  hanging until the editor kills it. An editor that closed the pipe is not
  coming back, so halting is the right answer.

  End of file on stdin is not the only sign. An editor that dies mid-reply
  closes its end of stdout first, and the write that fails takes OTP's tty
  driver down and the `user` process with it, the process that answers reads,
  so the read waiting on stdin never returns, not even with end of file. The
  transport therefore watches `user` and halts the moment it is gone, and
  halts when a read fails as it does at end of file.
  """

  @behaviour GenLSP.Communication.Adapter

  alias GenLSP.Communication.Stdio

  @impl true
  def init(args) do
    watch_user()
    Stdio.init(args)
  end

  @impl true
  defdelegate listen(state), to: Stdio

  @impl true
  defdelegate write(body, state), to: Stdio

  @impl true
  def read(state, buffer) do
    case Stdio.read(state, buffer) do
      :eof -> System.halt(0)
      {:error, _reason} -> System.halt(0)
      other -> other
    end
  end

  # The reads and writes go through the group leader, which outlives `user`,
  # so a request in flight when `user` dies is never answered. A process of
  # its own watches `user` instead and halts the VM the moment it is gone.
  defp watch_user do
    case Process.whereis(:user) do
      nil ->
        :ok

      user ->
        spawn(fn ->
          ref = Process.monitor(user)

          receive do
            {:DOWN, ^ref, :process, ^user, _reason} -> System.halt(0)
          end
        end)

        :ok
    end
  end
end
