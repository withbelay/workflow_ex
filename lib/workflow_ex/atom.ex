defmodule WorkflowEx.Atom do
  @moduledoc """
  Allow "atom" as a field type for embedded_schema

  https://hexdocs.pm/ecto/Ecto.Schema.html#module-custom-types
  """
  use Ecto.Type

  @type t :: :atom

  def type, do: :string

  def cast(value) when is_binary(value), do: {:ok, String.to_atom(value)}
  def cast(value) when is_atom(value), do: {:ok, value}

  def load(value), do: {:ok, String.to_atom(value)}
  def dump(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  def dump(_), do: :error
end
