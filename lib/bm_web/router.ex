defmodule BmWeb.Router do
  use BmWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BmWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", BmWeb do
    pipe_through :browser

    live "/", HomeLive
    live "/runs/:id", RunLive
    live "/chat", ChatLive
  end

  # BM's local JSON API for the terminal client (plan 14.2); only answers this machine.
  pipeline :local_api do
    plug :accepts, ["json"]
    plug BmWeb.Plugs.LocalOnly
  end

  scope "/api", BmWeb.Api do
    pipe_through :local_api

    post "/goals", RunController, :create_goal
    get "/runs", RunController, :index
    get "/runs/:id", RunController, :show
    post "/runs/:id/commit", RunController, :commit
    post "/runs/:id/approvals/:dialog_id", RunController, :answer
    post "/runs/:id/pause", RunController, :pause
    post "/runs/:id/resume", RunController, :resume
    post "/runs/:id/tasks/:key/undo", RunController, :undo
    post "/runs/:id/:action", RunController, :decide
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:bm, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BmWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
