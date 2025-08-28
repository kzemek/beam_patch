# 0.2.1

* Elixir 1.19 compatibility - manually unload the temporary `BeamPatch.InjectedCode` module
    * Elixir 1.19 ignores `@compile {:autoload, false}` when the compiled module is not saved to disk

