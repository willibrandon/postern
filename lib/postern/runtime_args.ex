defmodule Postern.RuntimeArgs do
  @moduledoc """
  The command-line arguments, and whether the VM runs inside a Burrito binary.

  Burrito is a dependency of the release alone, so the calls into it are
  guarded at runtime rather than compiled away: a build without it then has
  a `standalone?/0` that is a check rather than a constant the type checker
  would fold into every caller.
  """

  @compile {:no_warn_undefined, [Burrito.Util, Burrito.Util.Args]}

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
