defmodule CassWeb.OrderController do
  @moduledoc """
  The single checkout entry point: `POST /orders`.

  This route is behind `:require_authenticated_user`, so a guest is already
  redirected to the log-in page before reaching this controller. The controller
  submits the client's requested line items (`product_variant_id` + `quantity`,
  nothing else) to `Cass.Orders.create_order/2`, which resolves all pricing,
  ownership, and stock server-side and returns a generic `:base` error rather
  than any detail about *why* an item was refused.

  A successful checkout redirects to the order page so the customer sees what
  they just bought (number, snapshot lines, and the server-derived total).
  """

  use CassWeb, :controller

  alias Cass.Orders

  def create(
        conn,
        %{"product_variant_id" => product_variant_id, "quantity" => quantity}
      ) do
    requested_items = [%{product_variant_id: product_variant_id, quantity: quantity}]
    place_order(conn, requested_items)
  end

  # Also accepts the full list shape (%{"order" => %{"requested_items" => [...]}})
  # for programmatic clients; checkout itself only ever cares about the list.
  def create(conn, %{"order" => %{"requested_items" => requested_items}})
      when is_list(requested_items) do
    place_order(conn, requested_items)
  end

  def create(conn, _params) do
    refusal =
      Ecto.Changeset.change(Cass.Orders.Order)
      |> Ecto.Changeset.add_error(:base, "the order request is invalid")

    render_checkout_error(conn, refusal)
  end

  defp place_order(conn, requested_items) do
    scope = conn.assigns.current_scope

    case Orders.create_order(scope, requested_items) do
      {:ok, order} ->
        conn
        |> put_flash(:info, "Order #{order.number} placed.")
        |> redirect(to: ~p"/orders/#{order.id}")

      {:error, changeset} ->
        render_checkout_error(conn, changeset)
    end
  end

  # A refused checkout shows the generic reason ("order request is invalid",
  # "an item is not available", "out of stock") and returns the shopper to the
  # page they posted from. The message is deliberately coarse, matching the
  # context API, so a direct POST cannot learn why something was refused.
  defp render_checkout_error(conn, changeset) do
    return_to =
      case Plug.Conn.get_req_header(conn, "referer") do
        [referer | _rest] -> referer
        _none -> ~p"/orders"
      end

    conn
    |> put_flash(:error, checkout_error_message(changeset))
    |> redirect(to: return_to)
  end

  defp checkout_error_message(changeset) do
    case List.keyfind(changeset.errors, :base, 0) do
      {_key, {message, _opts}} -> message
      _other -> "the order could not be placed"
    end
  end
end
