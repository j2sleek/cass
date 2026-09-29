defmodule Cass.Payments.Providers.PaystackTest do
  @moduledoc """
  The Paystack adapter through `Req.Test`: request shapes, response mapping, and
  signature-verified webhook parsing. No network ever leaves the test process.
  """
  use ExUnit.Case, async: true

  alias Cass.Payments.Provider.{CaptureResult, InitResult}
  alias Cass.Payments.Providers.Paystack

  @secret_key Application.compile_env(:cass, :paystack, []) |> Keyword.fetch!(:secret_key)

  describe "initialize_payment/4" do
    test "posts the email, amount, currency, and our reference and normalizes the response" do
      Req.Test.stub(:paystack, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/transaction/initialize"

        body = Req.Test.raw_body(conn) |> Jason.decode!()

        assert body["email"] == "buyer@example.com"
        assert body["amount"] == 1250
        assert body["currency"] == "USD"
        assert body["reference"] == "PY-TEST-REF"

        Req.Test.json(conn, %{
          "status" => true,
          "message" => "Authorization URL created",
          "data" => %{
            "authorization_url" => "https://checkout.paystack.com/legacy",
            "access_code" => "ACC-123",
            "reference" => "PY-TEST-REF",
            "id" => 77_241_310,
            "domain" => "test"
          }
        })
      end)

      assert {:ok, %InitResult{} = result} =
               Paystack.initialize_payment("buyer@example.com", 1250, "USD", "PY-TEST-REF")

      assert result.provider_reference == "PY-TEST-REF"
      assert result.checkout_url == "https://checkout.paystack.com/legacy"
      assert result.expires_at == nil
      assert result.metadata["access_code"] == "ACC-123"
      assert result.metadata["transaction_id"] == 77_241_310
    end

    test "returns a refused error when Paystack answers with a message" do
      Req.Test.stub(:paystack, fn conn ->
        Req.Test.json(conn, %{"status" => false, "message" => "Invalid API key"})
      end)

      assert {:error, {:paystack_refused, "Invalid API key"}} =
               Paystack.initialize_payment("buyer@example.com", 1250, "USD", "PY-TEST-REF")
    end

    test "returns an unexpected response error for a malformed success body" do
      Req.Test.stub(:paystack, fn conn ->
        Req.Test.json(conn, %{"status" => true, "data" => %{}})
      end)

      assert {:error, :unexpected_response} =
               Paystack.initialize_payment("buyer@example.com", 1250, "USD", "PY-TEST-REF")
    end
  end

  describe "verify_payment/1" do
    test "maps a successful transaction to a :succeeded capture" do
      Req.Test.stub(:paystack, fn conn ->
        assert conn.request_path == "/transaction/verify/PY-TEST-REF"
        Req.Test.json(conn, verified_payload("success", 1250, "USD"))
      end)

      assert {:ok, %CaptureResult{} = result} = Paystack.verify_payment("PY-TEST-REF")

      assert result.provider_reference == "PY-TEST-REF"
      assert result.status == :succeeded
      assert result.amount_cents == 1250
      assert result.currency == "USD"
      assert result.paid_at != nil
    end

    test "maps abandoned and failed transactions to :cancelled and :failed" do
      Req.Test.stub(:paystack, fn conn ->
        Req.Test.json(conn, verified_payload("abandoned", 1250, "USD"))
      end)

      assert {:ok, %CaptureResult{status: :cancelled} = _} =
               Paystack.verify_payment("PY-TEST-REF")

      Req.Test.stub(:paystack, fn conn ->
        Req.Test.json(conn, verified_payload("failed", 1250, "USD"))
      end)

      assert {:ok, %CaptureResult{status: :failed} = _} = Paystack.verify_payment("PY-TEST-REF")
    end

    test "returns a refused error for a failed verification response" do
      Req.Test.stub(:paystack, fn conn ->
        Req.Test.json(conn, %{"status" => false, "message" => "Reference not found"})
      end)

      assert {:error, {:paystack_refused, "Reference not found"}} =
               Paystack.verify_payment("PY-TEST-REF")
    end
  end

  describe "parse_webhook/2" do
    test "accepts a validly signed charge.success and normalizes it" do
      body = webhook_payload("PY-TEST-REF", "success", 1250, "USD")
      headers = %{"x-paystack-signature" => sign(body)}

      assert {:ok, %CaptureResult{} = result} = Paystack.parse_webhook(body, headers)

      assert result.provider_reference == "PY-TEST-REF"
      assert result.status == :succeeded
      assert result.amount_cents == 1250
      assert result.currency == "USD"
      assert result.paid_at != nil
      assert result.metadata["channel"] == "card"
      assert result.metadata["paystack_event"] == "charge.success"
    end

    test "rejects a signature that does not match the raw body" do
      body = webhook_payload("PY-TEST-REF", "success", 1250, "USD")
      headers = %{"x-paystack-signature" => Base.encode16(:crypto.strong_rand_bytes(32))}

      assert {:error, :invalid_signature} = Paystack.parse_webhook(body, headers)
    end

    test "rejects a missing signature header" do
      body = webhook_payload("PY-TEST-REF", "success", 1250, "USD")
      assert {:error, :invalid_signature} = Paystack.parse_webhook(body, %{})
    end

    test "signatures are verified over the exact bytes that were signed" do
      body = webhook_payload("PY-TEST-REF", "success", 1250, "USD")
      # Sign a *different* byte string and hand the signature with the real body:
      # the recomputed hash over the real body must not match.
      headers = %{"x-paystack-signature" => sign(body <> ";")}

      assert {:error, :invalid_signature} = Paystack.parse_webhook(body, headers)
    end

    test "ignores events that are not a payment capture" do
      body =
        Jason.encode!(%{
          "event" => "transfer.success",
          "data" => %{"reference" => "TRF_000", "amount" => 1250, "currency" => "USD"}
        })

      headers = %{"x-paystack-signature" => sign(body)}

      assert {:ok, :ignored} = Paystack.parse_webhook(body, headers)
    end

    test "defaults malformed event data to a :failed (never :succeeded) capture" do
      body = webhook_payload("PY-TEST-REF", "weird", 1250, "USD")
      headers = %{"x-paystack-signature" => sign(body)}

      assert {:ok, %CaptureResult{status: :failed} = _} = Paystack.parse_webhook(body, headers)
    end

    test "rejects an undecodable payload" do
      body = "{not json"

      assert {:error, :invalid_signature} =
               Paystack.parse_webhook(body, %{
                 "x-paystack-signature" => sign("not the body")
               })

      assert {:error, :invalid_payload} =
               Paystack.parse_webhook(body, %{"x-paystack-signature" => sign(body)})
    end
  end

  defp verified_payload(status, amount, currency) do
    %{
      "status" => true,
      "message" => "Verification successful",
      "data" => %{
        "id" => 77_241_310,
        "reference" => "PY-TEST-REF",
        "status" => status,
        "amount" => amount,
        "currency" => currency,
        "paid_at" => "2026-09-29T12:00:00.000Z",
        "channel" => "card"
      }
    }
  end

  defp webhook_payload(reference, status, amount, currency) do
    Jason.encode!(%{
      "event" => "charge.success",
      "data" => %{
        "id" => 77_241_310,
        "reference" => reference,
        "status" => status,
        "amount" => amount,
        "currency" => currency,
        "paid_at" => "2026-09-29T12:00:00.000Z",
        "channel" => "card"
      }
    })
  end

  defp sign(body), do: Base.encode16(:crypto.mac(:hmac, :sha512, @secret_key, body), case: :lower)
end
