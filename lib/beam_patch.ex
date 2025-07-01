defmodule BeamPatch do
  @moduledoc false

  defstruct [:module, :filename, :forms, :compile_opts, :bytecode]

  # These options don't work with our usage of `:compile.forms/2`
  @filter_out_compile_opts [:from_core, :no_core_prepare]

  def new(module) do
    {^module, bytecode, _filename} = :code.get_object_code(module)

    forms = abstract_code(bytecode)

    %__MODULE__{
      module: module,
      filename: file_attribute(forms) || ~c"",
      forms: forms,
      compile_opts: compile_opts(bytecode)
    }
  end

  def remap_functions(%__MODULE__{} = patch, mappings) do
    forms =
      for form <- patch.forms do
        with {:function, _, name, arity, _} <- form,
             {:ok, new_name} <- Map.fetch(mappings, {name, arity}),
             do: rename_function(form, new_name),
             else: (_ -> form)
      end

    %{patch | forms: forms}
  end

  def compile(%__MODULE__{} = patch) do
    compile_opts =
      [:return_errors, :return_warnings | patch.compile_opts] -- @filter_out_compile_opts

    {:ok, _module, bytecode, _warnings} = :compile.forms(patch.forms, compile_opts)

    %{patch | bytecode: bytecode}
  end

  def load(%__MODULE__{} = patch) do
    {:module, _} = :code.load_binary(patch.module, patch.filename, patch.bytecode)
  end

  def inject_functions(%__MODULE__{} = patch, body) do
    existing_functions = collect_functions(patch.forms)

    functions_quoted =
      for {name, arity} <- existing_functions,
          name != :__info__ do
        args = for i <- 1..arity, do: {:"arg#{i}", [generated: true], nil}

        quote do
          defp unquote(name)(unquote_splicing(args)), do: :ok
        end
      end

    bytecode =
      compile_quoted(
        quote do
          defmodule Es6Maps.InjectedCode do
            unquote(body)
            unquote_splicing(functions_quoted)
          end
        end,
        to_string(patch.filename)
      )

    new_forms =
      for {:function, _, name, arity, _} = fun <- abstract_code(bytecode),
          {name, arity} not in existing_functions,
          do: fun

    {before_forms, after_forms} =
      Enum.split_while(patch.forms, &(not match?({:function, _, _, _, _}, &1)))

    forms = before_forms ++ new_forms ++ after_forms
    %{patch | forms: forms}
  end

  defp compile_quoted(quoted, filename) do
    {{:ok, [{_, bytecode}]}, _} =
      Code.with_diagnostics(fn ->
        old_compiler_options =
          Code.compiler_options(
            debug_info: true,
            ignore_module_conflict: true,
            no_warn_undefined: :all,
            infer_signatures: false
          )

        try do
          {:ok, Code.compile_quoted(quoted, filename)}
        rescue
          err -> {:error, err}
        after
          Code.compiler_options(old_compiler_options)
        end
      end)

    bytecode
  end

  defp collect_functions(forms) do
    for {:function, _, name, arity, _} <- forms,
        into: MapSet.new(),
        do: {name, arity}
  end

  defp rename_function({:function, meta, _name, arity, clauses}, new_name),
    do: {:function, meta, new_name, arity, clauses}

  defp file_attribute(forms) do
    Enum.find_value(forms, fn
      {:attribute, _, :file, {filename, _}} -> filename
      _ -> nil
    end)
  end

  defp abstract_code(bytecode) do
    {:ok, {_, abstract_code: abstract_code}} = :beam_lib.chunks(bytecode, [:abstract_code])
    {:raw_abstract_v1, abstract} = abstract_code
    abstract
  end

  defp compile_opts(bytecode) do
    {:ok, {_, compile_info: info}} = :beam_lib.chunks(bytecode, [:compile_info])
    Keyword.fetch!(info, :options)
  end
end
