defmodule CassWeb.PurchaseLive do
  @moduledoc """
  The access page for one purchase: `GET /purchases/:id`.

  This is the surface where Milestone 8's distinction becomes visible to a
  buyer. An **entitlement** proves the purchase succeeded and the buyer holds the
  right; this page shows **delivery** — how that right is actually exercised.

  It deliberately does no authorization work of its own. The page resolves
  exactly one thing, `Cass.Delivery.authorize_access(current_scope, id)`, and
  that one call decides authentication, ownership, entitlement state, and
  whether the purchase's delivery mechanism is exercisable at all. The page
  renders the granted capability or the shared not-found state; it never
  re-derives "is this mine?", never reads `user_id` from the URL, and never
  reimplements the active/revoked/expired rule.

  Because every refusal — unknown id, somebody else's purchase, a revoked
  grant, an elapsed one, and a mechanism this milestone cannot issue yet — comes
  back as the same refusal, they all render as the same page. A buyer cannot use
  this URL to discover whether an id exists, whose it was, or why it failed.

  The page is `noindex`: it is a private capability, never a public listing, and
  it is reachable from the buyer's own order page rather than from a dashboard.
  """
  use CassWeb, :live_view

  alias Cass.Ai
  alias Cass.Delivery
  alias CassWeb.NotFound

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:page_title, "Your access · CASS Marketplace")
    |> assign(:meta_description, "Access details for a purchase.")
    |> assign(:robots, "noindex, nofollow")
    |> assign(:access, nil)
    |> assign(:purchase_not_found, true)
    |> assign(:balance, nil)
    |> assign(:runs, [])
    |> assign(:prompt_form, to_form(%{}, as: :ai_run))
    |> assign(:result, nil)
    |> assign(:max_prompt_chars, 8000)
    |> ok()
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply, resolve(socket, id)}
  end

  defp resolve(socket, id) do
    # One call, one decision. Ownership, entitlement state, and mechanism all
    # live behind it, so this page cannot grant what the context refuses.
    socket = assign(socket, access: nil, purchase_not_found: true, result: nil)

    case Delivery.authorize_access(socket.assigns.current_scope, id) do
      {:ok, access} ->
        socket
        |> assign(:access, access)
        |> assign(:purchase_not_found, false)
        |> assign(:page_title, "#{access.product_name} · Your access · CASS Marketplace")
        |> load_ai_state(access)

      {:error, _refusal} ->
        socket
    end
  end

  # Balance and run history only exist for a metered purchase, so they are read
  # here rather than in `mount/3`: they depend on the entitlement, which is not
  # known until the id has been resolved.
  defp load_ai_state(socket, %{mechanism: :ai_gateway} = access) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:balance, Ai.balance(scope, access.entitlement_id))
    |> assign(:runs, Ai.recent_runs(scope, access.entitlement_id, 5))
  end

  defp load_ai_state(socket, _access), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <%= if @purchase_not_found do %>
        <NotFound.not_found resource="purchase" />
      <% else %>
        <.access_details access={@access} />
        <%!-- The run panel is a metered-AI surface; a digital or access-code
              purchase has nothing to run, so it must not be offered one. --%>
        <.ai_panel
          :if={@access.mechanism == :ai_gateway}
          balance={@balance}
          runs={@runs}
          result={@result}
          prompt_form={@prompt_form}
          available={Ai.available?()}
          max_prompt_chars={@max_prompt_chars}
        />
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate_prompt", %{"ai_run" => params}, socket) do
    {:noreply, assign(socket, :prompt_form, to_form(params, as: :ai_run))}
  end

  def handle_event("run", %{"ai_run" => %{"prompt" => prompt}}, socket) do
    %{access: access, current_scope: scope} = socket.assigns

    case Ai.complete(scope, access.entitlement_id, prompt) do
      {:ok, completion} ->
        {:noreply,
         socket
         |> put_flash(:info, "Done. One credit spent.")
         |> assign(:result, completion.content)
         |> assign(:prompt_form, to_form(%{}, as: :ai_run))
         |> load_ai_state(access)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, refusal_message(changeset))
         |> load_ai_state(access)}
    end
  end

  def handle_event("run", _params, socket), do: {:noreply, socket}

  # The gateway's own refusals are already buyer-safe sentences, so the first
  # changeset message is shown as-is. The fallback only fires for a shape that
  # carries no message at all, which is not something a buyer can act on either
  # way.
  defp refusal_message(%Ecto.Changeset{errors: errors}) do
    Enum.find_value(errors, "That run could not be completed.", fn {message, _opts} ->
      if is_binary(message), do: message
    end)
  end

  defp refusal_message(_other), do: "That run could not be completed."

  attr :access, :any, required: true

  defp access_details(assigns) do
    ~H"""
    <section class="mx-auto w-full max-w-3xl">
      <div class="border-b border-zinc-200/70 pb-8 dark:border-white/10">
        <p class="text-xs font-semibold tracking-widest text-brand-700 uppercase dark:text-brand-300">
          Delivered
        </p>
        <h1 class="mt-2 text-3xl font-bold tracking-tight text-zinc-900 sm:text-4xl dark:text-white">
          {@access.product_name}
        </h1>
        <p class="mt-3 text-base leading-7 text-zinc-600 dark:text-zinc-300">
          You bought this, it was delivered, and this is how you use it.
        </p>
      </div>

      <%= if @access.mechanism == :access_code do %>
        <div
          id="access-code-panel"
          class="mt-8 rounded-2xl border border-brand-200 bg-brand-50/60 p-6 shadow-sm dark:border-brand-500/30 dark:bg-brand-500/10"
        >
          <h2 class="text-sm font-semibold tracking-tight text-zinc-900 dark:text-white">
            Your access code
          </h2>
          <p class="mt-2 text-sm leading-6 text-zinc-600 dark:text-zinc-300">
            Keep this code. It is how this purchase is recognised, and it is the
            same every time you come back here.
          </p>
          <p
            id="access-code"
            class="mt-4 select-all font-mono text-2xl font-semibold tracking-[0.2em] text-zinc-900 sm:text-3xl dark:text-white"
          >
            {@access.access_code}
          </p>
        </div>
      <% end %>

      <dl id="access-details" class="mt-8 grid gap-6 sm:grid-cols-2">
        <.detail label="Product">
          {@access.product_name}
        </.detail>
        <.detail label="Configuration">{@access.variant_name}</.detail>
        <.detail label="Quantity">{@access.quantity}</.detail>
        <.detail label="Delivered via">{mechanism_label(@access.mechanism)}</.detail>
        <.detail label="Granted">{Calendar.strftime(@access.granted_at, "%b %-d, %Y")}</.detail>
        <.detail label="Access ends">
          <%= if @access.expires_at do %>
            {Calendar.strftime(@access.expires_at, "%b %-d, %Y")}
          <% else %>
            <span class="text-zinc-500 dark:text-zinc-400">Does not expire</span>
          <% end %>
        </.detail>
        <%= if @access.sku do %>
          <.detail label="SKU">{@access.sku}</.detail>
        <% end %>
      </dl>

      <p class="mt-10 text-xs leading-5 text-zinc-500 dark:text-zinc-400">
        Lost this code? It is tied to the purchase, so it has not changed — and if you
        no longer have access, it stops working immediately.
      </p>
    </section>
    """
  end

  attr :balance, :any, required: true
  attr :runs, :list, required: true
  attr :result, :any, required: true
  attr :prompt_form, :any, required: true
  attr :available, :boolean, required: true
  attr :max_prompt_chars, :integer, required: true

  defp ai_panel(assigns) do
    ~H"""
    <section id="ai-panel" class="mx-auto mt-10 w-full max-w-3xl">
      <div
        id="credit-balance"
        class="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm dark:border-white/10 dark:bg-zinc-900"
      >
        <div class="flex flex-wrap items-baseline justify-between gap-3">
          <h2 class="text-sm font-semibold tracking-tight text-zinc-900 dark:text-white">
            Credits remaining
          </h2>
          <p
            id="credit-balance-value"
            class="text-3xl font-bold tracking-tight text-zinc-900 dark:text-white"
          >
            {remaining(@balance)}
          </p>
        </div>
        <p class="mt-2 text-sm leading-6 text-zinc-600 dark:text-zinc-300">
          Each run spends one credit. Credits come from the tier you bought and
          never expire.
        </p>
      </div>

      <.form
        for={@prompt_form}
        id="ai-run-form"
        phx-change="validate_prompt"
        phx-submit="run"
        class="mt-6 rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm dark:border-white/10 dark:bg-zinc-900"
      >
        <label
          for="ai-run-form-prompt"
          class="text-sm font-semibold tracking-tight text-zinc-900 dark:text-white"
        >
          Your prompt
        </label>
        <p class="mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-300">
          Sent to our AI gateway to run this purchase. It is not stored with your account.
        </p>
        <textarea
          id="ai-run-form-prompt"
          name="ai_run[prompt]"
          rows="5"
          maxlength={@max_prompt_chars}
          placeholder="Paste the draft you want rewritten…"
          class="mt-3 block w-full rounded-xl border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 shadow-sm transition focus:border-brand-500 focus:ring-2 focus:ring-brand-500/30 focus:outline-none dark:border-white/15 dark:bg-zinc-950 dark:text-white"
        >
        </textarea>
        <div class="mt-4 flex items-center gap-4">
          <button
            id="ai-run-submit"
            type="submit"
            phx-disable-with="Running..."
            disabled={!@available or remaining(@balance) == 0}
            class="rounded-xl bg-zinc-900 px-4 py-2 text-sm font-semibold text-white shadow-sm transition hover:bg-zinc-700 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-zinc-900 disabled:cursor-not-allowed disabled:opacity-40 dark:bg-white dark:text-zinc-900 dark:hover:bg-zinc-200"
          >
            Run it
          </button>
          <%= unless @available do %>
            <p id="ai-unavailable" class="text-sm text-amber-700 dark:text-amber-400">
              The AI gateway is not configured, so runs are unavailable right now.
            </p>
          <% end %>
          <%= if @available and remaining(@balance) == 0 do %>
            <p id="ai-no-credits" class="text-sm text-amber-700 dark:text-amber-400">
              You have spent all your credits.
            </p>
          <% end %>
        </div>
      </.form>

      <%= if @result do %>
        <div
          id="ai-result"
          class="mt-6 rounded-2xl border border-brand-200 bg-brand-50/60 p-6 shadow-sm dark:border-brand-500/30 dark:bg-brand-500/10"
        >
          <h2 class="text-sm font-semibold tracking-tight text-zinc-900 dark:text-white">
            Result
          </h2>
          <p class="mt-3 text-sm leading-7 whitespace-pre-wrap text-zinc-800 dark:text-zinc-100">
            {@result}
          </p>
        </div>
      <% end %>

      <%= if @runs != [] do %>
        <details id="ai-run-history" class="mt-6">
          <summary class="cursor-pointer text-sm font-semibold text-zinc-900 dark:text-white">
            Recent runs
          </summary>
          <ul class="mt-3 space-y-2">
            <%= for run <- @runs do %>
              <li
                id={"ai-run-#{run.id}"}
                class="flex items-center justify-between gap-4 rounded-xl border border-zinc-200 px-3 py-2 text-sm dark:border-white/10"
              >
                <span class="text-zinc-700 dark:text-zinc-300">{run.status}</span>
                <span class="text-xs text-zinc-500 dark:text-zinc-400">
                  {Calendar.strftime(run.inserted_at, "%b %-d, %Y")}
                </span>
              </li>
            <% end %>
          </ul>
        </details>
      <% end %>
    </section>
    """
  end

  # A purchase with no credit pool yet renders as zero rather than a blank, so
  # the panel can never claim a balance that does not exist.
  defp remaining(nil), do: 0

  defp remaining(%Ai.CreditBalance{} = balance), do: Ai.CreditBalance.remaining(balance)

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp detail(assigns) do
    ~H"""
    <div>
      <dt class="text-xs font-semibold tracking-wide text-zinc-500 uppercase dark:text-zinc-400">
        {@label}
      </dt>
      <dd class="mt-1 text-sm text-zinc-900 dark:text-white">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  defp mechanism_label(:access_code), do: "Access code"
  defp mechanism_label(:ai_gateway), do: "AI gateway credits"
  defp mechanism_label(mechanism), do: mechanism |> to_string() |> String.replace("_", " ")

  defp ok(socket), do: {:ok, socket}
end
