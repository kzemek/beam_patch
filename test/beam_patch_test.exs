defmodule BeamPatchTest do
  use ExUnit.Case
  doctest BeamPatch

  test "String.jaro_distance/2" do
    assert String.jaro_distance("same", "same") == 1.0

    String
    |> BeamPatch.new()
    |> BeamPatch.remap_functions(%{{:jaro_distance, 2} => :jaro_distance_orig})
    |> BeamPatch.inject_functions(
      quote do
        def jaro_distance(a, b), do: jaro_distance_orig(a, b) * 2
      end
    )
    |> BeamPatch.compile()
    |> BeamPatch.load()

    assert String.jaro_distance("same", "same") == 2.0
  end
end
