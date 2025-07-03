defmodule BeamPatchTest do
  use ExUnit.Case, async: false

  doctest BeamPatch

  require BeamPatch

  @jaro_quoted (quote do
                  @modifier 2
                  def jaro_distance(a, b), do: super(a, b) * @modifier
                end)

  describe "String.jaro_distance/2" do
    setup do
      on_exit(fn ->
        :code.purge(String)
        :code.load_file(String)
      end)

      assert String.jaro_distance("same", "same") == 1.0

      :ok
    end

    test "patch!" do
      String
      |> BeamPatch.patch! do
        unquote(@jaro_quoted)
      end
      |> BeamPatch.load!()

      assert String.jaro_distance("same", "same") == 2.0
    end

    test "patch_and_load!" do
      BeamPatch.patch_and_load! String do
        unquote(@jaro_quoted)
      end

      assert String.jaro_distance("same", "same") == 2.0
    end

    test "patch_quoted!" do
      patch = BeamPatch.patch_quoted!(String, @jaro_quoted)
      BeamPatch.load!(patch)

      assert String.jaro_distance("same", "same") == 2.0
    end

    test "patch_quoted" do
      assert {:ok, patch} = BeamPatch.patch_quoted(String, @jaro_quoted)
      assert :ok = BeamPatch.load(patch)

      assert String.jaro_distance("same", "same") == 2.0
    end

    test "patch_quoted_and_load!" do
      BeamPatch.patch_quoted_and_load!(String, @jaro_quoted)

      assert String.jaro_distance("same", "same") == 2.0
    end

    test "patch_quoted_and_load" do
      assert :ok = BeamPatch.patch_quoted_and_load(String, @jaro_quoted)

      assert String.jaro_distance("same", "same") == 2.0
    end
  end

  describe "errors" do
    test "missing object code" do
      assert_raise BeamPatch.AbstractCodeError,
                   "error loading abstract code for module :not_a_module: :beam_file_missing",
                   fn -> BeamPatch.patch_quoted!(:not_a_module, nil) end
    end

    test "compile quoted error" do
      assert_raise BeamPatch.CompileError,
                   """
                   quoted compilation error:
                     - undefined function undefined_function/1 (there is no such import)
                   """,
                   fn -> BeamPatch.patch_quoted!(String, quote(do: undefined_function(1))) end
    end

    test "module load error" do
      :code.stick_mod(String)
      on_exit(fn -> :code.unstick_mod(String) end)

      assert_raise BeamPatch.ModuleLoadError,
                   "error loading module String: :sticky_directory",
                   fn -> String |> BeamPatch.patch_quoted!(nil) |> BeamPatch.load!() end
    end

    test "beam file missing" do
      defmodule NoBeamFileModule do
      end

      assert_raise BeamPatch.AbstractCodeError,
                   "error loading abstract code for module BeamPatchTest.NoBeamFileModule: :beam_file_missing",
                   fn -> BeamPatch.patch_quoted!(NoBeamFileModule, nil) end
    end

    test "abstract code missing" do
      assert_raise BeamPatch.AbstractCodeError,
                   "error loading abstract code for module NoDebugInfoModule: :abstract_code_chunk_missing",
                   fn -> BeamPatch.patch_quoted!(NoDebugInfoModule, nil) end
    end
  end

  describe "compilation-time patching" do
    test "doesn't leave a .beam file" do
      assert {:error, :nofile} = Code.ensure_loaded(BeamPatch.InjectedCode)
    end

    test "doesn't leave the module loaded" do
      refute Code.loaded?(BeamPatch.InjectedCode)
    end
  end
end
