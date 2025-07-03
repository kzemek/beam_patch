defmodule CompileTimePatch do
  @moduledoc false
  require BeamPatch

  @patch BeamPatch.patch_quoted!(String, do: nil)

  def patch, do: @patch
end
