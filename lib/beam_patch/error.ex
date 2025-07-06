defmodule BeamPatch.Error do
  @moduledoc """
  Errors that can be raised by BeamPatch.
  """

  @typedoc """
  The type of errors that can be returned by BeamPatch.
  """
  @type t ::
          BeamPatch.InternalError.t()
          | BeamPatch.InvalidOverrideError.t()
          | BeamPatch.AbstractCodeError.t()
          | BeamPatch.CompileError.t()
          | BeamPatch.ModuleLoadError.t()

  @doc """
  Defines all errors that can be raised by BeamPatch.
  Can be used to distinguish them in the `raise` block.

  ## Examples

      try do
        BeamPatch.patch_quoted!(String, do: nil)
      rescue
        e in BeamPatch.Error.t() -> e
      end
  """
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
  @moduledoc """
  An internal error that should not happen.

  This error is raised when an unexpected error occurs. This can mean abnormal
  environment, or a bug in BeamPatch.

  ## Fields
  - `:raw` - The original Elixir error that caused this error.
  """

  defexception [:raw]

  @type t :: %__MODULE__{raw: Exception.t()}

  @impl Exception
  def message(%__MODULE__{} = e) do
    "internal error: (#{inspect(e.raw.__struct__)}) #{Exception.message(e.raw)}"
  end
end

defmodule BeamPatch.InvalidOverrideError do
  @moduledoc """
  An error that is raised when an `@override` is used in an invalid way.

  ## Fields
  - `:reason` (`t:reason/0`) - The reason for the error.
  """

  @typedoc """
  The reason for the error.

  - `:unresolved_override` - The `@override` was found without a function definition.
  - `{:invalid_options, [invalid_option]}` - The `@override` was used with invalid options.
  - `{:no_base_implementation, [{name, arity}]}` - No base implementation was found for the function
  """
  @type reason ::
          :unresolved_override
          | {:invalid_options, [invalid_option :: atom()]}
          | {:no_base_implementation, [{function_name :: atom(), arity :: non_neg_integer()}]}

  defexception [:reason]

  @type t :: %__MODULE__{reason: reason()}

  @impl Exception
  def message(%__MODULE__{} = e) do
    "invalid `@override`: #{inspect(e.reason)}"
  end
end

defmodule BeamPatch.AbstractCodeError do
  @moduledoc """
  An error that is raised when abstract code cannot be loaded.

  ## Fields
  - `:module` (`t:module/0`) - The module under inspection.
  - `:reason` (`t:reason/0`) - The reason for the error.
  """
  defexception [:module, :reason]

  @typedoc """
  The reason for the error.

  - `:beam_file_missing` - .beam file for the module cannot be found.
  - `{:unknown_abstract_code_type, type}` - The abstract code type in the beam chunk is unknown.
  - `:abstract_code_chunk_missing` - The abstract code chunk is missing - usually means the module
    was not compiled with `:debug_info` enabled.
  - `:compile_info_chunk_missing` - The compile info chunk is missing.
  """
  @type reason ::
          :beam_file_missing
          | {:unknown_abstract_code_type, atom()}
          | :abstract_code_chunk_missing
          | :compile_info_chunk_missing

  @type t :: %__MODULE__{module: module(), reason: reason()}

  @impl Exception
  def message(%__MODULE__{} = e) do
    "error loading abstract code for module #{inspect(e.module)}: #{inspect(e.reason)}"
  end
end

defmodule BeamPatch.CompileError do
  @moduledoc """
  An error that is raised when a quoted or forms compilation fails.

  ## Fields
  - `:errors` ([`t:String.t/0`]) - The errors that occurred during compilation.
  - `:stage` (`:quoted | :forms`) - The stage of compilation that failed.
  """
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
  @moduledoc """
  An error that is raised when a module cannot be loaded.

  ## Fields
  - `:module` (`t:module/0`) - The module that couldn't be loaded.
  - `:reason` (`:badarg` | `t::code.load_error_rsn/0`) - The reason for the error.
  """
  defexception [:module, :reason]

  @type t :: %__MODULE__{module: module(), reason: :badarg | :code.load_error_rsn()}

  @impl Exception
  def message(%__MODULE__{} = e) do
    "error loading module #{inspect(e.module)}: #{inspect(e.reason)}"
  end
end
