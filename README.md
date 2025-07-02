# BeamPatch

[![CI](https://github.com/kzemek/beam_patch/actions/workflows/ci.yml/badge.svg)](https://github.com/kzemek/beam_patch/actions/workflows/ci.yml)
[![Module Version](https://img.shields.io/hexpm/v/beam_patch.svg)](https://hex.pm/packages/beam_patch)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/beam_patch/)
[![License](https://img.shields.io/hexpm/l/beam_patch.svg)](https://github.com/kzemek/beam_patch/blob/master/LICENSE)

Patch Elixir & Erlang modules at runtime

## Example

```elixir
require BeamPatch

assert String.jaro_distance("same", "same") == 1.0

BeamPatch.patch_and_load! String do
  @modifier 2
  def jaro_distance(a, b), do: super(a, b) * @modifier
end

assert String.jaro_distance("same", "same") == 2.0
```

## Installation

```elixir
def deps do
  [
    {:beam_patch, "~> 0.1.0"}
  ]
end
```
