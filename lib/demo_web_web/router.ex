defmodule DemoWebWeb.Router do
  use DemoWebWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DemoWebWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DemoWebWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/gitops", GitOpsLive, :index
    live "/terminal", TerminalLive, :index
    live "/terminal/:app", TerminalLive, :app
  end

  # Other scopes may use custom stacks.
  # scope "/api", DemoWebWeb do
  #   pipe_through :api
  # end
end
