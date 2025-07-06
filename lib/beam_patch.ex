defmodule BeamPatch do
  @external_resource "README.md"
  @moduledoc File.read!("README.md")
             |> String.replace(~r/^.*?(?=Patch Elixir & Erlang modules at runtime)/s, "")
             |> String.replace("> [!WARNING]", "> #### Warning {: .warning}")
             |> String.replace("> [!IMPORTANT]", "> #### Important {: .info}")

  require Record
  require BeamPatch.Error

  defmodule Patch do
    defstruct [:module, :filename, :bytecode]
    @type t :: %__MODULE__{module: module(), filename: charlist(), bytecode: binary()}
  end

  # These options don't work with our usage of `:compile.forms/2`
  @filter_out_compile_opts [:from_core, :no_core_prepare]
  @compile_quoted_opts [
    debug_info: true,
    ignore_module_conflict: true,
    no_warn_undefined: :all,
    infer_signatures: false
  ]

  Record.defrecordp(:function, [:ann, :name, :arity, :clauses])

  defmacro patch!(module, do: body) do
    quote do
      unquote(__MODULE__).patch_quoted!(unquote(module), unquote(Macro.escape(body)))
    end
  end

  defmacro patch_and_load!(module, do: body) do
    quote do
      unquote(__MODULE__).patch_quoted_and_load!(unquote(module), unquote(Macro.escape(body)))
    end
  end

  @spec patch_quoted_and_load(module(), body :: Macro.t()) ::
          {:ok, Patch.t()} | {:error, BeamPatch.Error.t()}
  def patch_quoted_and_load(module, body) do
    patch_quoted_and_load!(module, body)
  rescue
    e in BeamPatch.Error.t() -> {:error, e}
  end

  @spec load(Patch.t()) :: :ok | {:error, BeamPatch.Error.t()}
  def load(%Patch{} = patch) do
    load!(patch)
  rescue
    e in BeamPatch.Error.t() -> {:error, e}
  end

  @spec patch_quoted_and_load!(module(), body :: Macro.t()) :: :ok
  def patch_quoted_and_load!(module, body) do
    module |> patch_quoted!(body) |> load!()
  end

  @spec load!(Patch.t()) :: :ok
  def load!(%Patch{} = patch) do
    case :code.load_binary(patch.module, patch.filename, patch.bytecode) do
      {:module, _} -> :ok
      {:error, reason} -> raise BeamPatch.ModuleLoadError, module: patch.module, reason: reason
    end
  end

  @spec patch_quoted(module(), body :: Macro.t()) ::
          {:ok, Patch.t()} | {:error, BeamPatch.Error.t()}
  def patch_quoted(module, body) do
    {:ok, patch_quoted!(module, body)}
  rescue
    e in BeamPatch.Error.t() -> {:error, e}
  end

  @spec patch_quoted!(module(), body :: Macro.t()) :: Patch.t()
  def patch_quoted!(module, body) do
    orig_bytecode = get_object_code!(module)
    orig_forms = abstract_code!(module, orig_bytecode)
    filename = file_attribute(orig_forms)
    compile_opts = compile_opts!(module, orig_bytecode)

    nodes =
      case body do
        {:__block__, _, nodes} -> nodes
        _ -> List.wrap(body)
      end

    name_mappings = parse_override_mappings!(nodes)
    parsed_nodes = parse_out_overrides(nodes)
    mapped_forms = map_overriden_functions(orig_forms, name_mappings)

    existing_functions_set =
      for function(name: name, arity: arity) <- mapped_forms,
          into: MapSet.new(),
          do: {name, arity}

    compiled_module_bytecode =
      parsed_nodes
      |> prepare_injected_quote(existing_functions_set)
      |> compile_quoted!(filename)

    compiled_module_forms = abstract_code!(compiled_module_bytecode)

    injected_function_forms =
      for function(name: name, arity: arity) = fun <- compiled_module_forms,
          {name, arity} not in existing_functions_set,
          do: fun

    {before_forms, after_forms} =
      Enum.split_while(mapped_forms, &(not match?(function(), &1)))

    new_forms = before_forms ++ injected_function_forms ++ after_forms
    new_bytecode = compile_forms!(new_forms, compile_opts)

    %Patch{module: module, filename: filename, bytecode: new_bytecode}
  rescue
    e in BeamPatch.Error.t() -> reraise e, __STACKTRACE__
    e -> reraise BeamPatch.InternalError, [raw: e], __STACKTRACE__
  end

  defp prepare_injected_quote(nodes, existing_functions_set) do
    existing_functions_quoted =
      for {name, arity} <- existing_functions_set, name != :__info__ do
        args =
          for {name, meta, ctx} <- Macro.generate_arguments(arity, nil),
              do: {name, [generated: true] ++ meta, ctx}

        quote do
          def unquote(name)(unquote_splicing(args)), do: :erlang.nif_error(:beam_patch_stub)
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

  defp parse_out_overrides(nodes) do
    Enum.reject(nodes, &match?({:@, _, [{:override, _, _}]}, &1))
  end

  defp parse_override_mappings!(nodes) do
    {mappings, last_override} =
      Enum.flat_map_reduce(nodes, nil, fn
        {:@, _, [{:override, _, opts_or_ctx}]}, nil ->
          {[], validate_override_opts!(opts_or_ctx)}

        {:@, _, [{:override, _, _}]} = node, _opts ->
          raise BeamPatch.InvalidOverrideError,
                "`#{Macro.to_string(node)}` found following an unresolved @override"

        _node, nil ->
          {[], nil}

        {def_, _, [{name, _, ctx}, _body]}, opts when def_ in [:def, :defp] ->
          arity = if is_atom(ctx), do: 0, else: length(ctx)
          {[{{name, arity}, opts}], nil}

        _node, opts ->
          {[], opts}
      end)

    if last_override != nil do
      raise BeamPatch.InvalidOverrideError, "@override found without a function"
    end

    Map.new(mappings)
  end

  defp validate_override_opts!(opts_or_ctx) do
    case opts_or_ctx do
      [opts] when is_list(opts) -> opts
      ctx when is_atom(ctx) -> []
    end
    |> Keyword.validate!(original: [])
    |> Keyword.fetch!(:original)
    |> Keyword.validate!(rename_to: nil)
    |> Map.new()
  rescue
    e in ArgumentError ->
      reraise BeamPatch.InvalidOverrideError,
              "invalid @override options: #{Exception.message(e)}",
              __STACKTRACE__
  end

  defp map_overriden_functions(forms, name_mappings) do
    Enum.flat_map(forms, fn
      function(name: name, arity: arity) = form ->
        case name_mappings[{name, arity}] do
          nil -> [form]
          opts -> if opts[:rename_to], do: [function(form, name: opts[:rename_to])], else: []
        end

      form ->
        [form]
    end)
  end

  defp compile_quoted!(quoted, filename) do
    {result, diagnostics} =
      with_emulated_runtime_compilation(fn ->
        with_compiler_options(@compile_quoted_opts, fn ->
          Code.with_diagnostics(fn ->
            try do
              {:ok, Code.compile_quoted(quoted, to_string(filename))}
            rescue
              err in CompileError -> {:error, err}
            end
          end)
        end)
      end)

    case result do
      {:ok, [{_, bytecode}]} ->
        bytecode

      {:error, %CompileError{}} ->
        errors = for %{severity: :error, message: message} <- diagnostics, do: message
        raise BeamPatch.CompileError, stage: :quoted, errors: errors
    end
  end

  # TODO: this can be done by running in a task instead
  # Clean the dictionary so that the compiler doesn't see the compilation
  # as "happening in compilation time", and doesn't generate a .beam file.
  defp with_emulated_runtime_compilation(fun) do
    process_dict = Process.get()
    for {key, _} <- process_dict, do: Process.delete(key)

    try do
      fun.()
    after
      for {key, value} <- process_dict, do: Process.put(key, value)
    end
  end

  defp with_compiler_options(opts, fun) do
    old_compiler_options = Code.compiler_options(opts)

    try do
      fun.()
    after
      Code.compiler_options(old_compiler_options)
    end
  end

  defp compile_forms!(forms, compile_opts) do
    compile_opts = [:return_errors, :return_warnings | compile_opts] -- @filter_out_compile_opts

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
      {:attribute, _, :file, {filename, _}} -> filename
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
