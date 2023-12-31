using System.Linq;
using System.Threading.Tasks;
using BattleBitAPI.Common;
using ChaosMode.API;
using ChaosMode.Interfaces;

namespace ChaosMode.Modules;

public class ChatRewrite : ServerModule
{
    /// <summary>
    /// Stolen from https://github.com/DasIschBims/Lifesteal
    /// </summary>
    
    public override Task<bool> OnPlayerTypedMessage(BattleBitPlayer player, ChatChannel channel, string msg)
    {
        if (msg.StartsWith("!")) return Task.FromResult(false);

        Enums.PlayerRoles highestRole = player.GetHighestRole();
        var prefix = player.GetPrefixForHighestRole(highestRole);
        var suffix = player.GetSuffixForHighestRole(highestRole);

        var team = player.Team switch
        {
            Team.TeamA => "US",
            Team.TeamB => "RU",
            _ => string.Empty
        };

        switch (channel)
        {
            case ChatChannel.TeamChat:
                foreach (var teamPlayer in Server.AllPlayers.Where(p => p.Team == player.Team))
                {
                    var colorCodedName = teamPlayer.Team == player.Team
                        ? $"<color={IChatColorChannels.GoodGuys}>{player.Name}</color>"
                        : $"<color={IChatColorChannels.BadGuys}>{player.Name}</color>";

                    var rewrittenMessage = $"{prefix}{colorCodedName}{suffix} [{team}]: {msg}";

                    Server.SayToChat(rewrittenMessage, teamPlayer);
                }

                return Task.FromResult(false);
            case ChatChannel.AllChat:
                foreach (var teamPlayer in Server.AllPlayers)
                {
                    var colorCodedName = teamPlayer.Team == player.Team
                        ? $"<color={IChatColorChannels.GoodGuys}>{player.Name}</color>"
                        : $"<color={IChatColorChannels.BadGuys}>{player.Name}</color>";

                    var rewrittenMessage = $"{prefix}{colorCodedName}{suffix}: {msg}";

                    Server.SayToChat(rewrittenMessage, teamPlayer);
                }
                return Task.FromResult(false);
        }
        
        return Task.FromResult(true);
    }

    public ChatRewrite(BattleBitServer server) : base(server)
    {
    }
}