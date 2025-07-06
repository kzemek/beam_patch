defmodule BeamPatch.Error do
  @type t ::
          BeamPatch.InternalError.t()
          | BeamPatch.InvalidOverrideError.t()
          | BeamPatch.AbstractCodeError.t()
          | BeamPatch.CompileError.t()
          | BeamPatch.ModuleLoadError.t()

  defmacro t do
    Macro.escape([
      BeamPatch.InternalError,
      BeamPatch.InvalidOverrideError,
      BeamPatch.AbstractCodeError,
      BeamPatch.CompileError,
      BeamPatch.ModuleLoadError
    ])
  end
end

defmodule BeamPatch.InternalError do
  defexception [:raw]

  @type t :: %__MODULE__{raw: Exception.t()}

  @impl Exception
  def message(%__MODULE__{} = e) do
    "internal error: (#{inspect(e.raw.__struct__)}) #{Exception.message(e.raw)}"
  end
end

defmodule BeamPatch.InvalidOverrideError do
  defexception [:message]
  @type t :: %__MODULE__{message: String.t()}
end

defmodule BeamPatch.AbstractCodeError do
  defexception [:module, :reason]

  @type t :: %__MODULE__{
          module: module(),
          reason:
            :beam_file_missing
            | {:unknown_abstract_code_type, atom()}
            | :abstract_code_chunk_missing
            | :compile_info_chunk_missing
        }

  @impl Exception
  def message(%__MODULE__{} = e) do
    "error loading abstract code for module #{inspect(e.module)}: #{inspect(e.reason)}"
  end
end

defmodule BeamPatch.CompileError do
  defexception [:errors, :stage]

  @type t :: %__MODULE__{errors: [String.t()], stage: :quoted | :forms}

  @impl Exception
  def message(%__MODULE__{} = e) do
    """
    #{e.stage} compilation error:
    #{Enum.map_join(e.errors, "\n", &"  - #{&1}")}
    """
  end
end

defmodule BeamPatch.ModuleLoadError do
  defexception [:module, :reason]

  @type t :: %__MODULE__{module: module(), reason: any()}

  @impl Exception
  def message(%__MODULE__{} = e) do
    "error loading module #{inspect(e.module)}: #{inspect(e.reason)}"
  end
end
