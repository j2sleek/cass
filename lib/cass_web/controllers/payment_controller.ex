defmodule CassWeb.PaymentController do
  @moduledoc """
  The single "pay for this order" entry point: `POST /orders/:id/pay`.

  This route is behind `:require_authenticated_user`, and `Cass.Payments`
  resolves the order through the caller's scope, so the controller never
  decides ownership: an account pays its own orders, an admin may initialize
  any order, and a foreign or unknown id is the same refusal as a missing one.

  There is nothing to submit — no amount, no currency, no provider choice. The
  controller just hands the order id to `Cass.Payments.initialize_payment/3`,
  which assigns the money and provider server-side, and the customer is sent to
  the hosted checkout when it succeeds. Any failure redirects back to the order
  page with a generic message; a direct POST learns nothing about *why*.
  """

  use CassWeb, :controller

  alias Cass.Payments

  def create(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Payments.initialize_payment(scope, id, []) do
      {:ok, %{checkout_url: checkout_url}} when is_binary(checkout_url) ->
        redirect(conn, external: checkout_url)

      {:error, :not_found} ->
        render_not_found(conn, id)

      {:error, changeset} ->
        render_payment_error(conn, id, changeset)
    end
  end

  def create(conn, _params) do
    render_not_found(conn, "unknown")
  end

  defp render_not_found(conn, _id) do
    conn
    |> put_flash(:error, "that order could not be paid")
    |> redirect(to: ~p"/orders")
  end

  defp render_payment_error(conn, id, changeset) do
    message =
      case List.keyfind(changeset.errors, :base, 0) do
        {_key, {message, _opts}} -> message
        _other -> "the payment could not be started"
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/orders/#{id}")
  end
end
