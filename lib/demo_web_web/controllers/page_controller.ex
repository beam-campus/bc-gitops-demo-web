defmodule DemoWebWeb.PageController do
  use DemoWebWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
