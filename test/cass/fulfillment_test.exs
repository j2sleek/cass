defmodule Cass.FulfillmentTest do
  use ExUnit.Case, async: true

  alias Cass.Fulfillment

  describe "kind_for/1" do
    test "maps each product type to its fulfillment kind" do
      assert Fulfillment.kind_for(:digital) == :digital
      assert Fulfillment.kind_for(:smm) == :smm
      assert Fulfillment.kind_for(:ai) == :ai
      assert Fulfillment.kind_for(:service) == :manual
    end

    test "accepts a product and reads its product type" do
      product = %Cass.Catalog.Product{product_type: :ai}
      assert Fulfillment.kind_for(product) == :ai
    end

    test "unknown or future types degrade to manual fulfillment" do
      assert Fulfillment.kind_for(:tickets) == :manual
    end
  end
end
