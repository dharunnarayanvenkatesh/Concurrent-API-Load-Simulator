defmodule StressSimulatorWeb.ErrorHTML do
  use StressSimulatorWeb, :html

  # Render 404
  def render("404.html", _assigns) do
    "Not found"
  end

  # Render 500
  def render("500.html", _assigns) do
    "Internal server error"
  end

  # Catch-all
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
