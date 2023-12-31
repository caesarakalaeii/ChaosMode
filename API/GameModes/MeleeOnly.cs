﻿using BattleBitAPI.Common;
using ChaosMode.API.GameModes;

namespace ChaosMode.API;

public class MeleeOnly : GameMode
{
    public MeleeOnly(BattleBitServer r) : base(r)
    {
        Name = "MeleeOnly";
    }

    public override Returner OnPlayerSpawning(BattleBitPlayer player, OnPlayerSpawnArguments request)
    {
        player.SetLightGadget("Pickaxe", 0, true);
        player.Modifications.RunningSpeedMultiplier = 1.25f;
        player.Modifications.FallDamageMultiplier = 0f;
        player.Modifications.JumpHeightMultiplier = 1.5f;
        return base.OnPlayerSpawning(player, request);
    }

    public override bool RefreshLoadout(BattleBitPlayer player)
    {
        player.SetLightGadget("Pickaxe", 0, true);

        return true;
    }
}