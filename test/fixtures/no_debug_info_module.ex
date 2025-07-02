defmodule NoDebugInfoModule do
  @moduledoc false
  @compile {:debug_info, false}
end
