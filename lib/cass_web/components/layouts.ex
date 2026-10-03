defmodule CassWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use CassWeb, :html

  alias Cass.Accounts.Scope

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the CASS brand mark used in the storefront header and footer.

  ## Examples

      <Layouts.brand_mark />

  """
  def brand_mark(assigns) do
    ~H"""
    <span class="inline-flex shrink-0 items-center gap-2.5">
      <span class="grid size-9 place-items-center rounded-xl bg-gradient-to-br from-brand-600 to-accent-600 shadow-sm">
        <svg viewBox="0 0 24 24" class="size-5 text-white" fill="none" aria-hidden="true">
          <path
            d="M17.5 6.5A7.5 7.5 0 1 0 17.5 17.5"
            stroke="currentColor"
            stroke-width="2.5"
            stroke-linecap="round"
          />
        </svg>
      </span>
      <span class="flex flex-col leading-none">
        <span class="text-base font-bold tracking-tight text-zinc-900 dark:text-white">
          CASS
        </span>
        <span class="text-[0.65rem] font-medium tracking-widest text-zinc-500 dark:text-zinc-400 uppercase">
          Marketplace
        </span>
      </span>
    </span>
    """
  end

  @doc """
  The storefront site header.

  Shared by `app/1` and by the dead-rendered landing page, so the primary
  navigation, the search entry point and the account actions have exactly one
  definition. `current_scope` may be `nil`, which is what a guest — and what
  the controller-rendered home page — has.
  """
  attr :current_scope, :map, default: nil

  def site_header(assigns) do
    ~H"""
    <header class="sticky top-0 z-30 border-b border-zinc-200/70 bg-white/85 backdrop-blur dark:border-white/10 dark:bg-[#0b0b14]/85">
      <div class="mx-auto flex h-16 w-full max-w-6xl items-center justify-between gap-4 px-4 sm:px-6 lg:px-8">
        <a
          href={~p"/"}
          class="rounded-lg outline-none focus-visible:ring-2 focus-visible:ring-brand-500"
          aria-label="CASS Marketplace home"
        >
          <Layouts.brand_mark />
        </a>
        <nav class="flex items-center gap-1.5 sm:gap-2" aria-label="Primary">
          <.link
            navigate={~p"/catalog"}
            id="nav-catalog"
            class="rounded-lg px-3 py-2 text-sm font-medium text-zinc-600 transition hover:bg-zinc-100 hover:text-brand-700 dark:text-zinc-300 dark:hover:bg-white/5 dark:hover:text-brand-300"
          >
            Catalog
          </.link>

          <CassWeb.Storefront.search_form
            id="header-search"
            class="hidden w-52 lg:block"
            placeholder="Search the catalog"
          />

          <%= if Scope.authenticated?(@current_scope) do %>
            <%!-- One place decides who sees the management link, and it is the
                same predicate the Catalog context authorizes creation with,
                so the nav can never advertise an area the context would
                refuse. --%>
            <.link
              :if={Cass.Catalog.can_create_owned_product?(@current_scope)}
              navigate={~p"/manage/products"}
              id="nav-manage-products"
              class="rounded-lg px-3 py-2 text-sm font-medium text-zinc-600 transition hover:bg-zinc-100 hover:text-brand-700 dark:text-zinc-300 dark:hover:bg-white/5 dark:hover:text-brand-300"
            >
              Manage products
            </.link>

            <.link
              navigate={~p"/users/settings"}
              id="nav-settings"
              class="rounded-lg px-3 py-2 text-sm font-medium text-zinc-600 transition hover:bg-zinc-100 hover:text-brand-700 dark:text-zinc-300 dark:hover:bg-white/5 dark:hover:text-brand-300"
            >
              Settings
            </.link>

            <%!-- `method="delete"` keeps this a real browser form: Phoenix
                renders it as POST + a hidden `_method=delete`, which
                Plug.MethodOverride turns into the DELETE the router
                declares, and a `_csrf_token` comes along with it. --%>
            <.form
              for={to_form(%{}, as: "user")}
              id="log-out-nav-form"
              action={~p"/users/log-out"}
              method="delete"
            >
              <button
                id="nav-log-out"
                type="submit"
                class="rounded-lg px-3 py-2 text-sm font-semibold text-zinc-700 transition hover:bg-zinc-100 hover:text-zinc-900 dark:text-zinc-200 dark:hover:bg-white/5 dark:hover:text-white"
              >
                Log out
              </button>
            </.form>
          <% else %>
            <.link
              navigate={~p"/users/log-in"}
              id="nav-log-in"
              class="rounded-lg px-3 py-2 text-sm font-medium text-zinc-600 transition hover:bg-zinc-100 hover:text-brand-700 dark:text-zinc-300 dark:hover:bg-white/5 dark:hover:text-brand-300"
            >
              Log in
            </.link>
            <.link
              navigate={~p"/users/register"}
              id="nav-register"
              class="rounded-lg bg-zinc-900 px-3 py-2 text-sm font-semibold text-white shadow-sm transition hover:bg-zinc-700 dark:bg-white dark:text-zinc-900 dark:hover:bg-zinc-200"
            >
              Create account
            </.link>
          <% end %>

          <Layouts.theme_toggle />
        </nav>
      </div>
    </header>
    """
  end

  @doc """
  The storefront site footer.

  Rendered by `app/1` and by the controller-rendered landing page so the legal
  line, the account links and the catalog links have a single definition.
  """
  attr :current_scope, :map, default: nil
  attr :categories, :list, default: []

  def site_footer(assigns) do
    ~H"""
    <footer
      id="about"
      class="scroll-mt-20 border-t border-zinc-200/70 bg-zinc-50/70 dark:border-white/10 dark:bg-white/[0.02]"
      aria-labelledby="footer-heading"
    >
      <div class="mx-auto w-full max-w-6xl px-4 py-16 sm:px-6 lg:px-8">
        <div class="grid grid-cols-1 gap-12 lg:grid-cols-12">
          <div class="lg:col-span-5">
            <Layouts.brand_mark />
            <p class="mt-5 max-w-sm text-sm leading-6 text-zinc-600 dark:text-zinc-300">
              A unified marketplace for digital products, compliant social marketing
              services, and AI-powered tools — built with Elixir, Phoenix LiveView,
              and PostgreSQL.
            </p>
            <p class="mt-4 max-w-sm text-xs leading-5 text-zinc-500 dark:text-zinc-400">
              Checkout and Paystack payments are live: a paid order is tracked line by
              line as a delivery, and completing a delivery records your access.
            </p>
          </div>

          <nav class="lg:col-span-3" aria-label="Marketplace">
            <h3 id="footer-heading" class="sr-only">Footer</h3>
            <p class="text-sm font-semibold text-zinc-900 dark:text-white">Marketplace</p>
            <ul class="mt-4 space-y-3 text-sm">
              <li>
                <.link
                  navigate={~p"/catalog"}
                  class="text-zinc-500 transition-colors hover:text-brand-700 dark:text-zinc-400 dark:hover:text-brand-300"
                >
                  Browse the catalog
                </.link>
              </li>
              <li>
                <.link
                  navigate={~p"/catalog?type=digital"}
                  class="text-zinc-500 transition-colors hover:text-brand-700 dark:text-zinc-400 dark:hover:text-brand-300"
                >
                  Digital products
                </.link>
              </li>
              <li>
                <.link
                  navigate={~p"/catalog?type=smm"}
                  class="text-zinc-500 transition-colors hover:text-brand-700 dark:text-zinc-400 dark:hover:text-brand-300"
                >
                  Social marketing services
                </.link>
              </li>
              <li>
                <.link
                  navigate={~p"/catalog?type=ai"}
                  class="text-zinc-500 transition-colors hover:text-brand-700 dark:text-zinc-400 dark:hover:text-brand-300"
                >
                  AI tools
                </.link>
              </li>
              <%= for category <- Enum.take(@categories, 6) do %>
                <li>
                  <.link
                    navigate={~p"/catalog/categories/#{category.slug}"}
                    class="text-zinc-500 transition-colors hover:text-brand-700 dark:text-zinc-400 dark:hover:text-brand-300"
                  >
                    {category.name}
                  </.link>
                </li>
              <% end %>
            </ul>
          </nav>

          <nav class="lg:col-span-2" aria-label="Account">
            <p class="text-sm font-semibold text-zinc-900 dark:text-white">Account</p>
            <ul class="mt-4 space-y-3 text-sm">
              <%= if Scope.authenticated?(@current_scope) do %>
                <li>
                  <.link
                    navigate={~p"/users/settings"}
                    class="text-zinc-500 transition-colors hover:text-brand-700 dark:text-zinc-400 dark:hover:text-brand-300"
                  >
                    Settings
                  </.link>
                </li>
                <li>
                  <.link
                    navigate={~p"/orders"}
                    class="text-zinc-500 transition-colors hover:text-brand-700 dark:text-zinc-400 dark:hover:text-brand-300"
                  >
                    Orders
                  </.link>
                </li>
              <% else %>
                <li>
                  <.link
                    navigate={~p"/users/log-in"}
                    class="text-zinc-500 transition-colors hover:text-brand-700 dark:text-zinc-400 dark:hover:text-brand-300"
                  >
                    Sign in
                  </.link>
                </li>
                <li>
                  <.link
                    navigate={~p"/users/register"}
                    class="text-zinc-500 transition-colors hover:text-brand-700 dark:text-zinc-400 dark:hover:text-brand-300"
                  >
                    Create an account
                  </.link>
                </li>
              <% end %>
              <li class="text-zinc-500 dark:text-zinc-400">
                Privacy <span class="ml-1 text-xs text-zinc-400 dark:text-zinc-500">(soon)</span>
              </li>
            </ul>
          </nav>

          <nav class="lg:col-span-2" aria-label="Developers">
            <p class="text-sm font-semibold text-zinc-900 dark:text-white">Developers</p>
            <ul class="mt-4 space-y-3 text-sm">
              <li>
                <a
                  href={~p"/api/v1/health"}
                  class="text-zinc-500 transition-colors hover:text-brand-700 dark:text-zinc-400 dark:hover:text-brand-300"
                >
                  Health endpoint
                </a>
              </li>
              <li class="text-zinc-500 dark:text-zinc-400">
                API reference
                <span class="ml-1 text-xs text-zinc-400 dark:text-zinc-500">(soon)</span>
              </li>
            </ul>
          </nav>
        </div>

        <div class="mt-12 flex flex-col items-start justify-between gap-3 border-t border-zinc-200 pt-8 text-xs text-zinc-500 dark:border-white/10 dark:text-zinc-400 sm:flex-row sm:items-center">
          <p>© 2026 CASS Marketplace</p>
          <p>Built with Phoenix on Elixir/OTP.</p>
        </div>
      </div>
    </footer>
    """
  end

  @doc """
  Renders your app layout.

  This function is typically invoked from every LiveView template,
  and it contains the application header, navigation, and main region.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-white text-zinc-800 dark:bg-[#0b0b14] dark:text-zinc-200">
      <Layouts.site_header current_scope={@current_scope} />

      <main class="mx-auto w-full max-w-6xl px-4 py-10 sm:px-6 lg:px-8">
        {render_slot(@inner_block)}
      </main>

      <Layouts.flash_group flash={@flash} />

      <Layouts.site_footer current_scope={@current_scope} />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle.

  The `data-theme` attribute is applied to the document root before the page
  loads by the script in `root.html.heex`. The `dark:` Tailwind variant is
  bound to `[data-theme=dark]` in `app.css`.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex flex-row items-center rounded-full border border-zinc-300 bg-zinc-100 p-0.5 dark:border-white/10 dark:bg-white/5">
      <span
        aria-hidden="true"
        class="absolute top-0.5 bottom-0.5 left-0.5 w-1/3 rounded-full border border-zinc-200 bg-white shadow-sm transition-[left] duration-200 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3"
      />

      <button
        type="button"
        class="relative grid size-7 cursor-pointer place-items-center rounded-full text-zinc-500 hover:text-zinc-800 dark:text-zinc-400 dark:hover:text-zinc-100"
        aria-label="Use system theme"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>

      <button
        type="button"
        class="relative grid size-7 cursor-pointer place-items-center rounded-full text-zinc-500 hover:text-zinc-800 dark:text-zinc-400 dark:hover:text-zinc-100"
        aria-label="Use light theme"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>

      <button
        type="button"
        class="relative grid size-7 cursor-pointer place-items-center rounded-full text-zinc-500 hover:text-zinc-800 dark:text-zinc-400 dark:hover:text-zinc-100"
        aria-label="Use dark theme"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end
end
