defmodule StressSimulatorWeb.CoreComponents do
  use Phoenix.Component

  attr :type, :string, default: "text"
  attr :value, :any, default: nil
  attr :rest, :global

  def input(assigns) do
    ~H"""
    <input type={@type} value={@value} {@rest} />
    """
  end
end
