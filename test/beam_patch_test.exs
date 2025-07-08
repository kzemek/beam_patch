defmodule BeamPatchTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined, [String]}

  require BeamPatch

  doctest BeamPatch

  use MarkdownDoctest, file: "README.md", except: &(&1 =~ "def deps")

  @jaro_quoted (quote do
                  @modifier 2

                  @override original: [rename_to: :jaro_distance_orig]
                  def jaro_distance(a, b), do: jaro_distance_orig(a, b) * @modifier
                end)

  setup do
    on_exit(fn ->
      :code.purge(String)
      :code.load_file(String)
    end)

    assert String.jaro_distance("same", "same") == 1.0

    :ok
  end

  describe "api" do
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

    test "patch_quoted_and_load with bytecode" do
      %BeamPatch.Patch{bytecode: patched_bytecode} =
        BeamPatch.patch_quoted!(String, nil, @jaro_quoted)

      assert String.jaro_distance("same", "same") == 1.0

      patch =
        BeamPatch.patch! String, patched_bytecode do
          @override original: [rename_to: :jaro_distance_orig2]
          def jaro_distance(a, b), do: jaro_distance_orig2(a, b) * 2
        end

      assert String.jaro_distance("same", "same") == 1.0

      BeamPatch.load!(patch)

      # Double patched
      assert String.jaro_distance("same", "same") == 4.0
    end
  end

  describe "@override" do
    test "replaces the function" do
      BeamPatch.patch_and_load! String do
        @override
        def jaro_distance(a, b), do: helper()

        defp helper, do: 123
      end

      assert String.jaro_distance("same", "same") == 123
    end

    test "renames the function" do
      BeamPatch.patch_and_load! String do
        @modifier 2

        @override original: [rename_to: :jaro_distance_orig]
        def jaro_distance(a, b), do: jaro_distance_orig(a, b) * @modifier
      end

      assert String.jaro_distance("same", "same") == 2.0
    end

    test "renames and exports the function" do
      BeamPatch.patch_and_load! String do
        @override original: [rename_to: :jaro_distance_orig, export?: true]
        def jaro_distance(a, b), do: jaro_distance_orig(a, b) * 2
      end

      assert String.jaro_distance("same", "same") == 2.0
      assert String.jaro_distance_orig("same", "same") == 1.0
    end

    test "honors visibility of injected functions" do
      BeamPatch.patch_and_load! String do
        @override original: [rename_to: :jaro_distance_orig]
        defp jaro_distance(a, b), do: jaro_distance_orig(a, b) * 2

        def jaro_distance_wrapper(a, b), do: jaro_distance(a, b)
      end

      refute function_exported?(String, :jaro_distance, 2)
      refute function_exported?(String, :jaro_distance_orig, 2)
      assert function_exported?(String, :jaro_distance_wrapper, 2)
      assert String.jaro_distance_wrapper("same", "same") == 2.0
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

    test "@override following an @override" do
      assert {:error, %BeamPatch.InvalidOverrideError{reason: :unresolved_override}} =
               BeamPatch.patch_quoted(
                 String,
                 quote do
                   @override

                   @modifier :hi
                   @override rename_to: :jaro_distance_orig
                   def jaro_distance(a, b), do: jaro_distance_orig(a, b) * @modifier
                 end
               )
    end

    test "@override without a function" do
      assert {:error, %BeamPatch.InvalidOverrideError{reason: :unresolved_override}} =
               BeamPatch.patch_quoted(
                 String,
                 quote do
                   @override
                 end
               )
    end

    test "@override with an invalid syntax" do
      assert {:error, %BeamPatch.InvalidOverrideError{reason: {:invalid_options, [:a]}}} =
               BeamPatch.patch_quoted(String, quote(do: @override(a: b)))
    end

    test "no base implementation found for @override" do
      assert_raise BeamPatch.InvalidOverrideError,
                   "invalid `@override`: {:no_base_implementation, [jaro_distance_nope: 2]}",
                   fn ->
                     BeamPatch.patch! String do
                       @override
                       def jaro_distance_nope(a, b), do: 123
                     end
                   end
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
