defmodule Cass.Ai.Gateways.NexusTest do
  @moduledoc """
  The Nexus adapter through `Req.Test`: the request it builds, the response it
  normalizes, and the HTTP statuses it maps onto the closed reason vocabulary.
  No network ever leaves the test process.

  The two properties worth stating up front, because they are what the adapter
  is *for*:

    * the gateway key is sent in a header and appears nowhere else — not in the
      completion, not in the logs;
    * a malformed or unexpected body never becomes a completion, because that
      text would be shown to a buyer as if it were a real answer.
  """
  use ExUnit.Case, async: true

  alias Cass.Ai.Completion
  alias Cass.Ai.Gateways.Nexus

  @api_key Application.compile_env(:cass, :nexus_ai, []) |> Keyword.fetch!(:api_key)

  defp stub_chat(completion, opts \\ []) do
    Req.Test.stub(:nexus_ai, fn conn ->
      unless Keyword.get(opts, :skip_request_assertions) do
        assert conn.method == "POST"
        assert conn.request_path == "/v1/chat/completions"

        assert {"content-type", "application/json"} =
                 List.keyfind(conn.req_headers, "content-type", 0)

        assert {"authorization", "Bearer " <> key} =
                 List.keyfind(conn.req_headers, "authorization", 0)

        assert key == @api_key
      end

      Req.Test.json(conn, completion)
    end)
  end

  defp chat_completion(content, opts \\ []) do
    %{
      "id" => "chatcmpl-test",
      "object" => "chat.completion",
      "model" => Keyword.get(opts, :model, "test-model"),
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => "stop"
        }
      ]
    }
  end

  describe "name/0" do
    test "is the atom the registry is keyed by" do
      assert Nexus.name() == :nexus
    end
  end

  describe "complete/3" do
    test "sends an OpenAI-shaped single-message request and normalizes the answer" do
      stub_chat(chat_completion("Rewritten: hi there, hope you are well."))

      assert {:ok, %Completion{} = completion} =
               Nexus.complete("test-model", "rewrite this: hi")

      assert completion.content == "Rewritten: hi there, hope you are well."
      assert completion.model == "test-model"
    end

    test "never requests a stream" do
      Req.Test.stub(:nexus_ai, fn conn ->
        body = Req.Test.raw_body(conn) |> Jason.decode!()

        # A streaming response would need an SSE reader on the adapter side, and
        # this milestone does not have one. Asking for one would guarantee a
        # failure the adapter cannot interpret.
        assert body["stream"] == false
        assert body["messages"] == [%{"role" => "user", "content" => "hello"}]

        Req.Test.json(conn, chat_completion("hi"))
      end)

      assert {:ok, %Completion{}} = Nexus.complete("test-model", "hello")
    end

    test "falls back to the configured default model when the purchase pins none" do
      Req.Test.stub(:nexus_ai, fn conn ->
        body = Req.Test.raw_body(conn) |> Jason.decode!()

        assert body["model"] == "default"

        Req.Test.json(conn, chat_completion("ok"))
      end)

      assert {:ok, %Completion{}} = Nexus.complete(nil, "hello")
    end

    test "reads usage counters when the gateway reports them" do
      Req.Test.stub(:nexus_ai, fn conn ->
        Req.Test.json(
          conn,
          Map.put(chat_completion("ok"), "usage", %{
            "prompt_tokens" => 11,
            "completion_tokens" => 4,
            "total_tokens" => 15
          })
        )
      end)

      assert {:ok, %Completion{prompt_tokens: 11, completion_tokens: 4}} =
               Nexus.complete("test-model", "hello")
    end

    test "a body with no usage is still a completion" do
      stub_chat(%{"choices" => [%{"message" => %{"content" => "ok"}}]})

      assert {:ok, %Completion{content: "ok", prompt_tokens: nil}} =
               Nexus.complete("test-model", "hello")
    end
  end

  describe "status mapping" do
    for {status, reason} <- [
          {401, :unauthorized},
          {403, :unauthorized},
          {429, :rate_limited},
          {400, :invalid_request},
          {404, :invalid_request},
          {500, :unavailable},
          {503, :unavailable}
        ] do
      test "#{status} becomes #{reason}" do
        Req.Test.stub(:nexus_ai, fn conn ->
          conn |> Plug.Conn.put_status(unquote(status)) |> Req.Test.json(%{"error" => "nope"})
        end)

        assert {:error, unquote(reason)} = Nexus.complete("test-model", "hello")
      end
    end
  end

  describe "a response that cannot be trusted" do
    test "empty choices are unavailable, not an empty answer" do
      Req.Test.stub(:nexus_ai, fn conn ->
        Req.Test.json(conn, %{"choices" => []})
      end)

      assert {:error, :unavailable} = Nexus.complete("test-model", "hello")
    end

    test "empty content is unavailable, not a blank completion" do
      stub_chat(chat_completion(""))

      assert {:error, :unavailable} = Nexus.complete("test-model", "hello")
    end

    test "an unrecognizable body is unavailable" do
      Req.Test.stub(:nexus_ai, fn conn -> Req.Test.json(conn, %{"unexpected" => true}) end)

      assert {:error, :unavailable} = Nexus.complete("test-model", "hello")
    end

    test "a blank prompt is rejected before any request is made" do
      assert {:error, :invalid_request} = Nexus.complete("test-model", "   ")
    end
  end

  describe "the gateway key" do
    test "appears in the request and nowhere in the result" do
      stub_chat(chat_completion("done"))

      assert {:ok, %Completion{} = completion} = Nexus.complete("test-model", "hello")

      refute inspect(completion) =~ @api_key
    end
  end
end
