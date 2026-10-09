defmodule CassWeb.Router do
  use CassWeb, :router

  import CassWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CassWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug CassWeb.Plugs.TrackPageView
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Provider webhooks are not browser sessions: no session, no CSRF. They are
  # authorized by the provider signature verified over the raw body.
  pipeline :webhooks do
    plug :accepts, ["json"]
  end

  ## Public browsing: the catalog and the authentication entry points.

  scope "/", CassWeb do
    pipe_through :browser

    get "/", PageController, :home

    live_session :current_user, on_mount: [{CassWeb.UserAuth, :mount_current_scope}] do
      live "/catalog", CatalogLive
      live "/catalog/categories/:slug", CategoryLive
      live "/catalog/products/:slug", ProductLive

      live "/users/register", UserRegistrationLive
      live "/users/log-in", UserLoginLive
      live "/users/reset-password", UserForgotPasswordLive
      live "/users/reset-password/:token", UserResetPasswordLive
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
    get "/users/confirm/:token", UserConfirmationController, :show
  end

  ## Signed-in only.

  scope "/", CassWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{CassWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserSettingsLive
      live "/orders", OrdersLive, :index
      live "/orders/:id", OrdersLive, :show
      live "/favorites", FavoritesLive
      # Delivery & access for one purchase (Milestone 8). The route is
      # authenticated; ownership and entitlement state are decided by
      # `Cass.Delivery.authorize_access/2`, never here.
      live "/purchases/:id", PurchaseLive
    end

    post "/orders", OrderController, :create
    post "/orders/:id/pay", PaymentController, :create
    get "/users/settings/confirm-email/:token", UserConfirmationController, :confirm_email
  end

  ## Sellers and admins only: the protected product management area.

  scope "/", CassWeb do
    pipe_through [:browser, :require_vendor_or_admin_user]

    live_session :require_vendor_or_admin,
      on_mount: [{CassWeb.UserAuth, :require_vendor_or_admin}] do
      live "/manage/products", ProductManagementLive, :index
      live "/manage/products/new", ProductManagementLive, :new
      live "/manage/products/:id/edit", ProductManagementLive, :edit
    end
  end

  ## Admins only: the analytics and insights dashboard.

  scope "/", CassWeb do
    pipe_through [:browser, :require_admin_user]

    live_session :require_admin,
      on_mount: [{CassWeb.UserAuth, :require_admin}] do
      live "/insights", InsightsLive
    end
  end

  scope "/api/v1", CassWeb.Api.V1 do
    pipe_through :api

    get "/health", HealthController, :show
  end

  ## Provider webhooks (no session, no CSRF — authorization is the signature).

  scope "/webhooks", CassWeb do
    pipe_through :webhooks

    post "/paystack", PaymentsWebhookController, :paystack
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:cass, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CassWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
