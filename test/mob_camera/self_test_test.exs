defmodule MobCamera.SelfTestTest do
  use ExUnit.Case, async: true

  alias MobCamera.SelfTest
  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("../..", __DIR__)
  @ios_sim %{platform: :ios, device: :simulator}
  @emulator %{platform: :android, device: :emulator}

  defmodule PassNif do
    def camera_stop_preview, do: :ok
  end

  defmodule UnregisteredBridgeNif do
    def camera_stop_preview, do: {:error, :bridge_not_registered}
  end

  defmodule NoJvmNif do
    def camera_stop_preview, do: :error
  end

  defmodule NotLoadedNif do
    def camera_stop_preview, do: :erlang.nif_error(:nif_not_loaded)
  end

  defmodule EmptyNif do
  end

  test "the manifest declares it and the validator raises no selftest warning" do
    {:ok, m} = Manifest.load(@plugin_dir)
    assert m.selftest == SelfTest
    assert %{errors: [], warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
    refute Enum.any?(warnings, &(&1 =~ "selftest"))
  end

  test "stop_preview answering :ok passes on both platforms, with or without a camera" do
    assert SelfTest.run(@ios_sim, PassNif) == :pass
    assert SelfTest.run(@emulator, PassNif) == :pass
  end

  test "an unregistered Kotlin bridge fails and says so" do
    assert {:fail, reason} = SelfTest.run(@emulator, UnregisteredBridgeNif)
    assert reason =~ "on android returned {:error, :bridge_not_registered}"
    assert reason =~ "MobCameraBridge was never registered"
    assert Mob.Plugin.SelfTest.result?({:fail, reason})
  end

  test "any other answer fails, naming what came back and what was expected" do
    assert SelfTest.run(@emulator, NoJvmNif) ==
             {:fail, "camera_stop_preview/0 on android returned :error, expected :ok"}
  end

  test "a NIF that is not loaded, or a missing export, fails naming the NIF instead of raising" do
    assert {:fail, not_loaded} = SelfTest.run(@ios_sim, NotLoadedNif)
    assert not_loaded =~ "MobCamera.SelfTestTest.NotLoadedNif is not linked into this build"
    assert not_loaded =~ "nif_not_loaded"

    assert {:fail, undef} = SelfTest.run(@ios_sim, EmptyNif)
    assert undef =~ "EmptyNif is not linked into this build"
  end

  test "on the host (stub .erl, no native library) run/1 fails naming :mob_camera_nif" do
    assert {:fail, reason} = SelfTest.run(@emulator)
    assert reason =~ ":mob_camera_nif is not linked into this build"
    assert reason =~ "nif_not_loaded"
    assert Mob.Plugin.SelfTest.result?({:fail, reason})
  end
end
