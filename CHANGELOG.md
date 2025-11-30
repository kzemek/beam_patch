# 0.2.2

* Accept missing compilation options in `:compile_info` BEAM chunk

# 0.2.1

* Elixir 1.19 compatibility - manually unload the temporary `BeamPatch.InjectedCode` module
    * Elixir 1.19 ignores `@compile {:autoload, false}` when the compiled module is not saved to disk

