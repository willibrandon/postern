defmodule Postern.Application do
  @moduledoc "Starts the Postern LSP application and its stdio transport."

  use Application

  @impl true
  def start(_type, _args) do
    args = runtime_args()

    cond do
      Enum.any?(args, &(&1 in Postern.CLI.info_flags())) ->
        System.halt(Postern.CLI.run(args))

      index = Enum.find_index(args, &(&1 == "check")) ->
        System.halt(Postern.CLI.run(Enum.drop(args, index)))

      true ->
        :ok
    end

    children =
      if Application.get_env(:postern, :stdio, true) do
        [
          {GenLSP.Buffer, communication: {Postern.Stdio, []}, name: GenLSP.Buffer},
          {GenLSP.Assigns, name: GenLSP.Assigns},
          {Task.Supervisor, name: Postern.TaskSupervisor},
          {Postern.Server,
           [
             buffer: GenLSP.Buffer,
             assigns: GenLSP.Assigns,
             task_supervisor: Postern.TaskSupervisor
           ]}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Postern.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      if children != [] and Postern.RuntimeArgs.standalone?(), do: keep_vm_alive()
      {:ok, pid}
    end
  end

  # Burrito's launcher starts the VM with `-s elixir start_cli` and passes only
  # the user's arguments after `-extra`. Without `--no-halt` among them, the
  # Elixir CLI resets `System.no_halt/1` and halts the VM the moment boot
  # completes, which kills the stdio server before the first request. Never
  # returning from `start/2` keeps boot from completing; the server halts the
  # VM itself when the client sends `exit`, and a supervisor crash takes this
  # linked process down with it.
  defp keep_vm_alive do
    Process.sleep(:infinity)
  end

  defp runtime_args do
    Postern.RuntimeArgs.argv()
  end
end
