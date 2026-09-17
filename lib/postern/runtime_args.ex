defmodule Postern.RuntimeArgs do
  @moduledoc """
  Provides command-line arguments in Mix and Burrito environments.
  """

  if Code.ensure_loaded?(Burrito.Util.Args) do
    alias Burrito.Util.Args, as: BurritoArgs

    @doc "Returns arguments passed to the Burrito executable."
    @spec argv() :: [String.t()]
    def argv, do: BurritoArgs.argv()

    @doc "Returns true when running inside a Burrito-wrapped binary."
    @spec standalone?() :: boolean()
    def standalone?, do: Burrito.Util.running_standalone?()
  else
    @doc "Returns the VM command-line arguments."
    @spec argv() :: [String.t()]
    def argv, do: System.argv()

    @doc "Returns true when running inside a Burrito-wrapped binary."
    @spec standalone?() :: boolean()
    # The module name is built at runtime, so a build without Burrito
    # compiles without a word about the missing module, and the type checker
    # sees a boolean rather than a literal false.
    def standalone? do
      util = Module.concat([Burrito, Util])
      Code.ensure_loaded?(util) and util.running_standalone?()
    end
  end
end
