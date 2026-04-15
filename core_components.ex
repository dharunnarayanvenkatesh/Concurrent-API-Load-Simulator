defmodule StressSimWeb.CoreComponents do
  @moduledoc "Core Phoenix components."
  use Phoenix.Component

  def flash(%{kind: :error} = assigns) do
    ~H"""
    <div class="alert alert-error"><%= @msg %></div>
    """
  end

  def flash(assigns), do: ~H""
end
