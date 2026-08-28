defmodule ExKalshi.QueryTest do
  use ExUnit.Case, async: true

  alias ExKalshi.Query

  doctest ExKalshi.Query

  test "drops disallowed keys and nils, expands lists" do
    assert Query.url("/p", [a: 1, b: nil, c: ["x", "y"], z: 9], [:a, :b, :c]) == "/p?a=1&c=x&c=y"
  end

  test "encodes booleans and special characters" do
    assert Query.encode([flag: true, s: "a b"], [:flag, :s]) == "flag=true&s=a+b"
  end
end
