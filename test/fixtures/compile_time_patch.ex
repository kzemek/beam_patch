defmodule CompileTimePatch do
  @moduledoc false

  @patch BeamPatch.patch_quoted!(
           String,
           quote do
             def hello, do: :world
           end
         )

  @spec load :: :ok
  def load, do: BeamPatch.load!(@patch)
end
