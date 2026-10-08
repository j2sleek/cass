defmodule CassWeb.LiveAnalytics do
  @moduledoc """
  A small, socket-aware shim over `Cass.Analytics.track/2` for LiveViews.

  It pulls the anonymous `visitor_id` and the signed-in `user_id` off the socket
  so a LiveView only has to describe the *event*, not the identity plumbing:

      CassWeb.LiveAnalytics.track(socket, "product_view",
        path: ~p"/catalog/products/\#{product.slug}",
        subject_type: "product",
        subject_id: product.id,
        metadata: %{"title" => product.name}
      )

  The `:visitor_id` assign is set by `CassWeb.UserAuth`'s `on_mount` hooks from
  the signed session, so it is present on every LiveView this app mounts.
  """
  alias Cass.Analytics
  alias Cass.Accounts.Scope

  @doc "Records an event for the caller of `socket`."
  @spec track(Phoenix.LiveView.Socket.t(), String.t(), keyword() | map()) :: :ok
  def track(socket, name, attrs \\ %{}) do
    attrs = Map.new(attrs)

    Analytics.track(name, %{
      visitor_id: socket.assigns[:visitor_id],
      user_id: user_id(socket.assigns[:current_scope]),
      path: attrs[:path],
      subject_type: attrs[:subject_type],
      subject_id: attrs[:subject_id],
      metadata: attrs[:metadata] || %{}
    })
  end

  defp user_id(%Scope{user: %{id: id}}), do: id
  defp user_id(_scope), do: nil
end
