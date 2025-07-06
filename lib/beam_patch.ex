defmodule BeamPatch do
  @external_resource "README.md"
  @moduledoc File.read!("README.md")
             |> String.replace(~r/^.*?(?=Patch Elixir & Erlang modules at runtime)/s, "")
             |> String.replace("> [!WARNING]", "> #### Warning {: .warning}")
             |> String.replace("> [!IMPORTANT]", "> #### Important {: .info}")

  require Record
  require BeamPatch.Error

  defmodule Patch do
    @moduledoc """
    A struct that represents a patched module, ready to be loaded.

    ## Fields
    - `:module` (`t:module/0`) - The module patched.
    - `:filename` (`t:charlist/0`) - The filename of the module, loaded from its abstract chunks.
    - `:bytecode` (`t:binary/0`) - The patched bytecode of the module.
    """
    defstruct [:module, :filename, :bytecode]
    @type t :: %__MODULE__{module: module(), filename: charlist(), bytecode: binary()}
  end

  @add_compile_opts [
    :binary,
    :return,
    :debug_info
  ]

  # These options don't work with our usage of `:compile.noenv_forms/2`
  @filter_out_compile_opts [
    :from_core,
    :no_core_prepare,
    :return_errors,
    :return_warnings
  ]

  @compile_quoted_opts [
    debug_info: true,
    ignore_module_conflict: true,
    no_warn_undefined: :all,
    infer_signatures: false
  ]

  Record.defrecordp(:function, [:ann, :name, :arity, :clauses])
  Record.defrecordp(:attribute, [:ann, :name, :value])

  @doc """
  Patch (without loading) a module with body given via `do end` block.

  This is sugar for `patch_quoted!/2` function.

  Raises one of `t:BeamPatch.Error.t/0` on error.
  """
  defmacro patch!(module, bytecode \\ nil, do: body) do
    quote do
      unquote(__MODULE__).patch_quoted!(
        unquote(module),
        unquote(bytecode),
        unquote(Macro.escape(body))
      )
    end
  end

  @doc """
  Patch and load a module with body given via `do end` block.

  This is sugar for `patch_quoted_and_load!/2` function.

  Raises one of `t:BeamPatch.Error.t/0` on error.
  """
  defmacro patch_and_load!(module, bytecode \\ nil, do: body) do
    quote do
      unquote(__MODULE__).patch_quoted_and_load!(
        unquote(module),
        unquote(bytecode),
        unquote(Macro.escape(body))
      )
    end
  end

  @doc """
  Patch and load a module with a quoted body.
  """
  @spec patch_quoted_and_load(module(), bytecode :: binary() | nil, body :: Macro.t()) ::
          {:ok, Patch.t()} | {:error, BeamPatch.Error.t()}
  def patch_quoted_and_load(module, bytecode \\ nil, body) do
    patch_quoted_and_load!(module, bytecode, body)
  rescue
    e in BeamPatch.Error.t() -> {:error, e}
  end

  @doc """
  Load a patched module.
  """
  @spec load(Patch.t()) :: :ok | {:error, BeamPatch.Error.t()}
  def load(%Patch{} = patch) do
    load!(patch)
  rescue
    e in BeamPatch.Error.t() -> {:error, e}
  end

  @doc """
  Patch and load a module with a quoted body.

  Raises one of `t:BeamPatch.Error.t/0` on error.
  """
  @spec patch_quoted_and_load!(module(), bytecode :: binary() | nil, body :: Macro.t()) :: :ok
  def patch_quoted_and_load!(module, bytecode \\ nil, body) do
    module |> patch_quoted!(bytecode, body) |> load!()
  end

  @doc """
  Load a patched module.

  Raises `t:BeamPatch.ModuleLoadError.t/0` on error.
  """
  @spec load!(Patch.t()) :: :ok
  def load!(%Patch{} = patch) do
    case :code.load_binary(patch.module, patch.filename, patch.bytecode) do
      {:module, _} -> :ok
      {:error, reason} -> raise BeamPatch.ModuleLoadError, module: patch.module, reason: reason
    end
  end

  @doc """
  Patch a module with a quoted body.
  """
  @spec patch_quoted(module(), bytecode :: binary() | nil, body :: Macro.t()) ::
          {:ok, Patch.t()} | {:error, BeamPatch.Error.t()}
  def patch_quoted(module, bytecode \\ nil, body) do
    {:ok, patch_quoted!(module, bytecode, body)}
  rescue
    e in BeamPatch.Error.t() -> {:error, e}
  end

  @doc """
  Patch a module with a quoted body.

  Raises one of `t:BeamPatch.Error.t/0` on error.
  """
  @spec patch_quoted!(module(), bytecode :: binary() | nil, body :: Macro.t()) :: Patch.t()
  def patch_quoted!(module, bytecode \\ nil, body) do
    orig_bytecode = bytecode || get_object_code!(module)
    orig_forms = abstract_code!(module, orig_bytecode)
    filename = file_attribute(orig_forms)
    compile_opts = compile_opts!(module, orig_bytecode)

    nodes =
      case body do
        {:__block__, _, nodes} -> nodes
        _ -> List.wrap(body)
      end

    name_mappings = parse_override_mappings!(nodes)
    parsed_nodes = filter_out_overrides(nodes)
    mapped_forms = map_overriden_functions!(orig_forms, name_mappings)
    function_visibility = parse_function_visibility(nodes)

    compiled_module_bytecode =
      parsed_nodes
      |> prepare_injected_quote(mapped_forms)
      |> compile_quoted!(filename)

    compiled_module_forms = abstract_code!(compiled_module_bytecode)

    injected_function_forms =
      for function(name: name, arity: arity) = fun <- compiled_module_forms,
          Map.has_key?(function_visibility, {name, arity}),
          do: fun

    {before_forms, after_forms} =
      mapped_forms
      |> adjust_exports(function_visibility, name_mappings)
      |> Enum.split_while(&(not match?(function(), &1)))

    new_forms = before_forms ++ injected_function_forms ++ after_forms
    new_bytecode = compile_forms!(new_forms, compile_opts)

    %Patch{module: module, filename: filename, bytecode: new_bytecode}
  rescue
    e in BeamPatch.Error.t() -> reraise e, __STACKTRACE__
    e -> reraise BeamPatch.InternalError, [raw: e], __STACKTRACE__
  end

  defp prepare_injected_quote(nodes, forms) do
    existing_functions_quoted =
      for function(name: name, arity: arity) <- forms, name != :__info__ do
        args =
          for {name, meta, ctx} <- Macro.generate_arguments(arity, nil),
              do: {name, [generated: true] ++ meta, ctx}

        quote do
          def unquote(name)(unquote_splicing(args)),
            do: :erlang.nif_error(:beam_patch_stub)
        end
      end

    quote do
      defmodule BeamPatch.InjectedCode do
        @moduledoc false
        @compile {:autoload, false}
        unquote_splicing(nodes)
        unquote_splicing(existing_functions_quoted)
      end
    end
  end

  defp adjust_exports(forms, function_visibility, name_mappings) do
    Enum.map(forms, fn
      attribute(name: :export, value: orig_exports) = attr ->
        filtered_orig_exports =
          for {name, arity} <- orig_exports,
              not Map.has_key?(name_mappings, {name, arity}) and
                not Map.has_key?(function_visibility, {name, arity}),
              do: {name, arity}

        new_function_exports =
          for {{name, arity}, true} <- function_visibility,
              do: {name, arity}

        renamed_exports =
          for {{_old_name, arity}, opts} <- name_mappings,
              opts.rename_to != nil,
              opts.export?,
              do: {opts.rename_to, arity}

        attribute(attr, value: filtered_orig_exports ++ new_function_exports ++ renamed_exports)

      form ->
        form
    end)
  end

  defp filter_out_overrides(nodes) do
    Enum.reject(nodes, &match?({:@, _, [{:override, _, _}]}, &1))
  end

  defp parse_override_mappings!(nodes) do
    nodes
    |> Enum.reduce(%{mappings: %{}, last_override_opts: nil}, fn
      {:@, _, [{:override, _, opts_or_ctx}]}, %{last_override_opts: nil} = acc ->
        %{acc | last_override_opts: validate_override_opts!(opts_or_ctx)}

      {:@, _, [{:override, _, _}]}, _opts ->
        raise BeamPatch.InvalidOverrideError, reason: :unresolved_override

      _node, %{last_override_opts: nil} = acc ->
        acc

      {def_, _, _} = node, acc when def_ in [:def, :defp] ->
        {name, arity} = ast_def_name_arity(node)
        new_mappings = Map.put(acc.mappings, {name, arity}, acc.last_override_opts)
        %{acc | mappings: new_mappings, last_override_opts: nil}

      _node, acc ->
        acc
    end)
    |> case do
      %{last_override_opts: nil} = acc -> acc.mappings
      _ -> raise BeamPatch.InvalidOverrideError, reason: :unresolved_override
    end
  end

  defp parse_function_visibility(nodes) do
    for {def_, _, _} = node when def_ in [:def, :defp] <- nodes,
        into: %{},
        do: {ast_def_name_arity(node), def_ == :def}
  end

  defp ast_def_name_arity({def_, _, [{name, _, ctx}, _body]}) when def_ in [:def, :defp],
    do: {name, if(is_atom(ctx), do: 0, else: length(ctx))}

  defp validate_override_opts!(opts_or_ctx) do
    opts =
      case opts_or_ctx do
        [opts] when is_list(opts) -> opts
        ctx when is_atom(ctx) -> []
      end

    with {:ok, opts} <- Keyword.validate(opts, original: []),
         opts = Keyword.fetch!(opts, :original),
         {:ok, opts} <- Keyword.validate(opts, rename_to: nil, export?: false) do
      Map.new(opts)
    else
      {:error, invalid_opts} ->
        raise BeamPatch.InvalidOverrideError, reason: {:invalid_options, invalid_opts}
    end
  end

  defp map_overriden_functions!(forms, name_mappings) do
    {new_forms, unconsumed_name_mappings} =
      Enum.flat_map_reduce(forms, name_mappings, fn
        function(name: name, arity: arity) = form, name_mappings
        when is_map_key(name_mappings, {name, arity}) ->
          {opts, new_name_mappings} = Map.pop!(name_mappings, {name, arity})
          new_form = if opts.rename_to, do: [function(form, name: opts.rename_to)], else: []
          {new_form, new_name_mappings}

        form, name_mappings ->
          {[form], name_mappings}
      end)

    if unconsumed_name_mappings != %{} do
      raise BeamPatch.InvalidOverrideError,
        reason: {:no_base_implementation, Map.keys(unconsumed_name_mappings)}
    end

    new_forms
  end

  defp compile_quoted!(quoted, filename) do
    fn -> Code.compile_quoted(quoted, to_string(filename)) end
    |> with_compiler_options(@compile_quoted_opts)
    |> with_compiler_error_rescue()
    |> with_compiler_diagnostics()
    |> with_emulated_runtime_compilation()
    |> apply([])
    |> case do
      {{:ok, [{_, bytecode}]}, _} ->
        bytecode

      {{:error, %CompileError{}}, diagnostics} ->
        errors = for %{severity: :error, message: message} <- diagnostics, do: message
        raise BeamPatch.CompileError, stage: :quoted, errors: errors
    end
  end

  # Compile out-of-process so that the compiler doesn't see the compilation
  # as "happening in compilation time", and doesn't generate a .beam file.
  defp with_emulated_runtime_compilation(fun),
    do: fn -> fun |> Task.async() |> Task.await(:infinity) end

  defp with_compiler_options(fun, opts) do
    fn ->
      old_compiler_options = Code.compiler_options(opts)

      try do
        fun.()
      after
        Code.compiler_options(old_compiler_options)
      end
    end
  end

  defp with_compiler_diagnostics(fun),
    do: fn -> Code.with_diagnostics(fun) end

  defp with_compiler_error_rescue(fun) do
    fn ->
      try do
        {:ok, fun.()}
      rescue
        err in CompileError -> {:error, err}
      end
    end
  end

  defp compile_forms!(forms, compile_opts) do
    compile_opts =
      Enum.uniq(@add_compile_opts ++ ([compile_opts] -- @filter_out_compile_opts))

    case :compile.noenv_forms(forms, compile_opts) do
      {:ok, _module, bytecode, _warnings} ->
        bytecode

      {:error, errors, _warnings} ->
        errors =
          for {_file, file_errors} <- errors,
              {_line, _module, error} <- file_errors,
              do: inspect(error)

        raise BeamPatch.CompileError, stage: :forms, errors: errors
    end
  end

  defp get_object_code!(module) do
    case :code.get_object_code(module) do
      {^module, bytecode, _filename} -> bytecode
      :error -> raise BeamPatch.AbstractCodeError, module: module, reason: :beam_file_missing
    end
  end

  defp file_attribute(forms) do
    Enum.find_value(forms, "", fn
      attribute(name: :file, value: {filename, _}) -> filename
      _ -> nil
    end)
  end

  defp abstract_code!(module \\ nil, bytecode) do
    case :beam_lib.chunks(bytecode, [:abstract_code]) do
      {:ok, {_, abstract_code: {:raw_abstract_v1, abstract}}} ->
        abstract

      {:ok, {_, abstract_code: {type, _abstract}}} ->
        raise BeamPatch.AbstractCodeError,
          module: module,
          reason: {:unknown_abstract_code_type, type}

      {:ok, {_, abstract_code: :no_abstract_code}} ->
        raise BeamPatch.AbstractCodeError,
          module: module,
          reason: :abstract_code_chunk_missing

      {:error, _, _} ->
        raise BeamPatch.AbstractCodeError,
          module: module,
          reason: :abstract_code_chunk_missing
    end
  end

  defp compile_opts!(module, bytecode) do
    case :beam_lib.chunks(bytecode, [:compile_info]) do
      {:ok, {_, compile_info: info}} ->
        Keyword.fetch!(info, :options)

      {:error, _, _} ->
        raise BeamPatch.AbstractCodeError,
          module: module,
          reason: :compile_info_chunk_missing
    end
  end
end
