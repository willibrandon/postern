defmodule Postern.RuntimeArgs do
  @moduledoc """
  The command-line arguments, and whether the VM runs inside a Burrito binary.

  Burrito starts only in a release. The calls into it are guarded at runtime
  so an ordinary Mix session uses the VM's arguments instead.
  """

  alias Burrito.Util.Args, as: BurritoArgs

  @doc "The arguments the program was started with, from Burrito's launcher or the VM."
  @spec argv() :: [String.t()]
  def argv do
    if standalone?(), do: BurritoArgs.argv(), else: System.argv()
  end

  @doc "Whether this VM runs inside a Burrito-wrapped binary."
  @spec standalone?() :: boolean()
  def standalone? do
    Code.ensure_loaded?(Burrito.Util) and Burrito.Util.running_standalone?()
  end
end
