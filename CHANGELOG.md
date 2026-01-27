# 0.2.3 (Unreleased)

* Ensure `defp` overrides aren't optimized out

* Ensure unique names for InjectedCode modules to allow concurrent compilation
  
  Fixes Elixir compiler errors `BeamPatch.InjectedCode is already being compiled`.

# 0.2.2

* Accept missing compilation options in `:compile_info` BEAM chunk

# 0.2.1

* Elixir 1.19 compatibility - manually unload the temporary `BeamPatch.InjectedCode` module
    * Elixir 1.19 ignores `@compile {:autoload, false}` when the compiled module is not saved to disk
