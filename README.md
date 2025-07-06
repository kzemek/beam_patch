# BeamPatch

[![CI](https://github.com/kzemek/beam_patch/actions/workflows/ci.yml/badge.svg)](https://github.com/kzemek/beam_patch/actions/workflows/ci.yml)
[![Module Version](https://img.shields.io/hexpm/v/beam_patch.svg)](https://hex.pm/packages/beam_patch)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/beam_patch/)
[![License](https://img.shields.io/hexpm/l/beam_patch.svg)](https://github.com/kzemek/beam_patch/blob/master/LICENSE)

Patch Elixir & Erlang modules at runtime

## Example

```elixir
iex> require BeamPatch
iex>
iex> String.jaro_distance("same", "same")
1.0
iex> BeamPatch.patch_and_load! String do
...>   @modifier 2
...>
...>   @override original: [rename_to: :jaro_distance_orig]
...>   def jaro_distance(a, b), do: jaro_distance_orig(a, b) * @modifier
...> end
iex>
iex> String.jaro_distance("same", "same")
2.0
```

### Changing function visibility

```elixir
iex> BeamPatch.patch_and_load! String do
...>   # Rename the original and make it public
...>   @override original: [rename_to: :jaro_distance_orig, export?: true]
...>   # As expected, `defp` keyword makes `jaro_distance/2` private
...>   defp jaro_distance(a, b), do: jaro_distance_orig(a, b) * 2
...>
...>   # Define a completely new function as a part of `String`'s interface
...>   def my_jaro_distance(a, b),
...>     do: jaro_distance(a, b) * jaro_distance_orig(a, b)
...> end
iex>
iex> function_exported?(String, :jaro_distance, 2)
false
iex> String.jaro_distance_orig("same", "same")
1.0
iex> String.my_jaro_distance("same", "same")
2.0
```

### Split patching and loading

```elixir
defmodule CompileTimePatch do
  # A common pattern is patching at compilation time,
  # but loading the patched module at runtime
  @patch BeamPatch.patch_quoted!(
           String,
           quote do
             def hello, do: :world
           end
         )

  def load, do: BeamPatch.load!(@patch)
end

iex> CompileTimePatch.load()
iex> String.hello()
:world
```

## Installation

```elixir
def deps do
  [
    {:beam_patch, "~> 0.2.0"}
  ]
end
```
