/**
 * 00. Includes
 * 01. Globals
 * 02. Forwards
 * 03. Events
 * 04. Functions
 */
 
// 00. Includes
#pragma semicolon 1
#include <sourcemod>
#include <cstrike>
#include <sdktools>
#include <sdktools_functions>
#include <sdkhooks>

// 01. Globals
#define GOVIP_MAINLOOP_INTERVAL 0.1
#define GOVIP_MAXPLAYERS 64

enum VIPState {
	VIPState_WaitingForMinimumPlayers = 0,
	VIPState_Playing
};

new CurrentVIP = 0;
new LastVIP = 0;
new VIPState:CurrentState = VIPState_WaitingForMinimumPlayers;
new Handle:CVarMinCT = INVALID_HANDLE;
new Handle:CVarMinT = INVALID_HANDLE;
new Handle:CVarVIPWeapon = INVALID_HANDLE;
new Handle:CVarVIPAmmo = INVALID_HANDLE;
new MyWeaponsOffset = 0;
new Handle:RescueZones = INVALID_HANDLE;
new bool:RoundComplete = false;
new Handle:hBotMoveTo = INVALID_HANDLE;

// 02. Forwards
public OnPluginStart() {
	CVarMinCT = CreateConVar("govip_min_ct", "2", "Minimum number of CTs to play GOVIP");
	CVarMinT = CreateConVar("govip_min_t", "1", "Minimum number of Ts to play GOVIP");
	CVarVIPWeapon = CreateConVar("govip_weapon", "weapon_p250", "Weapon given to VIP");
	CVarVIPAmmo = CreateConVar("govip_ammo", "12", "Ammo given to VIP");
	
	CurrentState = VIPState_WaitingForMinimumPlayers;
	
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_spawn", Event_PlayerSpawn);
	
	MyWeaponsOffset = FindSendPropOffs("CBaseCombatCharacter", "m_hMyWeapons");
	
	RescueZones = CreateArray();
	
	new Handle:hGameConf = LoadGameConfigFile("plugin.govip");
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "CCSBotMoveTo");
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	hBotMoveTo = EndPrepSDKCall();
	
	RoundComplete = false;
	
	for (new i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i)) {
			continue;
		}
		
		OnClientPutInServer(i);
	}
}

CCSBotMoveTo(bot, Float:origin[3]) {
	SDKCall(hBotMoveTo, bot, origin, 0);
}

public OnClientPutInServer(client) {
	SDKHook(client, SDKHook_WeaponCanUse, OnWeaponCanUse);
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
	return true;
}

public OnClientDisconnect(client) {
	if(CurrentState != VIPState_Playing || client != CurrentVIP || RoundComplete) {
		return;
	}
	
	RoundComplete = true;
	
	LastVIP = CurrentVIP;
	
	PrintToChatAll("%s", "[GO:VIP] The VIP has left, round ends in a draw.");
	
	CS_TerminateRound(5.0, CSRoundEnd_Draw);
}

public OnMapStart() {
	new trigger = -1;
	decl String:buffer[512];
	
	while((trigger = FindEntityByClassname(trigger, "trigger_multiple")) != -1) {
		if(GetEntPropString(trigger, Prop_Data, "m_iName", buffer, sizeof(buffer)) \
			&& StrContains(buffer, "vip_rescue_zone", false) == 0) {
			SDKHook(trigger, SDKHook_Touch, TouchRescueZone);
		}
	}
	
	CreateTimer(GOVIP_MAINLOOP_INTERVAL, GOVIP_MainLoop, INVALID_HANDLE, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

public OnConfigsExecuted()
{
	ProcessConfigurationFiles();
}

// 03. Events
public Event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast) {
	RoundComplete = false;
	
	CurrentVIP = GetRandomPlayerOnTeam(CS_TEAM_CT, LastVIP);
	
	if(CurrentState != VIPState_Playing) {
		return;
	}
	
	for (new i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && IsPlayerAlive(i)) {
			new iWeapon = GetPlayerWeaponSlot(i, 4);
			if (iWeapon != -1 && IsValidEdict(iWeapon)) {
				decl String:szClassName[64];
				GetEdictClassname(iWeapon, szClassName, sizeof(szClassName));
				if (StrEqual(szClassName, "weapon_c4", false)) {
					RemovePlayerItem(i, iWeapon);
					AcceptEntityInput(iWeapon, "Kill");
				}
			}
		}
	}
	
	RemoveMapObj();
	
	if(CurrentVIP == 0 || !IsValidPlayer(CurrentVIP)) {
		return;
	}
	
	PrintToChatAll("[GO:VIP] %N is the VIP, CTs protect the VIP from the Terrorists!", CurrentVIP);
	
	return;
}

public Event_RoundEnd(Handle:event, const String:name[], bool:dontBroadcast) {
	if(CurrentState != VIPState_Playing) {
		return;
	}
	
	RoundComplete = true; /* The round is 'ogre'. No point in continuing to track stats. */
}

public Action:Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast) {
	if(CurrentState != VIPState_Playing) {
		return Plugin_Continue;
	}
	
	new userid = GetEventInt(event, "userid");
	new client = GetClientOfUserId(userid);
	
	if(client != CurrentVIP || RoundComplete) {
		return Plugin_Continue;
	}
	
	RoundComplete = true;
	
	CS_TerminateRound(5.0, CSRoundEnd_TerroristWin);
	
	PrintToChatAll("%s", "[GO:VIP] The VIP has died, Terrorists win!");
	
	LastVIP = CurrentVIP;
	
	return Plugin_Continue;
}

public Action:Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast) {
	if(CurrentState != VIPState_Playing) {
		return Plugin_Continue;
	}
	
	new userid = GetEventInt(event, "userid");
	new client = GetClientOfUserId(userid);
	
	if(client != CurrentVIP) {
		return Plugin_Continue;
	}
	
	new String:VIPWeapon[256];
	GetConVarString(CVarVIPWeapon, VIPWeapon, sizeof(VIPWeapon));
	
	StripWeapons(client);
	
	new index = GivePlayerItem(client, VIPWeapon);
	
	if(index != -1) {
		SetAmmo(client, index, GetConVarInt(CVarVIPAmmo));
	}	
	
	return Plugin_Continue;
}

SetAmmo(client, weapon, ammo) {
	SetEntProp(client, Prop_Send, "m_iAmmo", ammo, _, GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType"));
}

// 04. Functions
public Action:GOVIP_MainLoop(Handle:timer) {
	new CTCount = GetTeamClientCount(CS_TEAM_CT);
	new TCount = GetTeamClientCount(CS_TEAM_T);
	
	if(CurrentState == VIPState_WaitingForMinimumPlayers) {
		if(CTCount >= GetConVarInt(CVarMinCT) && TCount >= GetConVarInt(CVarMinT)) {
			CurrentState = VIPState_Playing;
			PrintToChatAll("%s", "[GO:VIP] Starting the game!");
			return Plugin_Continue;
		}
	}
	else if(CurrentState == VIPState_Playing) {
		if(TCount < GetConVarInt(CVarMinT) || CTCount < GetConVarInt(CVarMinCT)) {
			CurrentState = VIPState_WaitingForMinimumPlayers;
			PrintToChatAll("%s", "[GO:VIP] Game paused, waiting for more players.");
			return Plugin_Continue;
		}
		
		if(CurrentVIP == 0) {
			RoundComplete = true;
			
			CurrentVIP = GetRandomPlayerOnTeam(CS_TEAM_CT, LastVIP);
				
			CS_TerminateRound(5.0, CSRoundEnd_GameStart); 
		}
		else if(!RoundComplete && IsValidPlayer(CurrentVIP)) {
			new Float:vipOrigin[3];
			GetClientAbsOrigin(CurrentVIP, vipOrigin);
			
			new rescueZoneCount = GetArraySize(RescueZones);
			
			if(rescueZoneCount > 0) {
				new Handle:rescueZone = GetArrayCell(RescueZones, 0);
					
				new Float:idealRescueZone[3];
				idealRescueZone[0] = GetArrayCell(rescueZone, 1);
				idealRescueZone[1] = GetArrayCell(rescueZone, 2);
				idealRescueZone[2] = GetArrayCell(rescueZone, 3);
					
				for(new pl = 1; pl < MaxClients; pl++) {
					if(IsValidPlayer(pl) && IsFakeClient(pl)) {
						CCSBotMoveTo(pl, idealRescueZone);
					}
				}	
			}
			
			for(new rescueZoneIndex = 0; rescueZoneIndex < rescueZoneCount; rescueZoneIndex++) {
				new Handle:rescueZone = GetArrayCell(RescueZones, rescueZoneIndex);
				
				new Float:rescueZoneOrigin[3];
				rescueZoneOrigin[0] = GetArrayCell(rescueZone, 1);
				rescueZoneOrigin[1] = GetArrayCell(rescueZone, 2);
				rescueZoneOrigin[2] = GetArrayCell(rescueZone, 3);
				
				new Float:rescueZoneRadius = GetArrayCell(rescueZone, 0);
				
				if(GetVectorDistance(rescueZoneOrigin, vipOrigin) <= rescueZoneRadius) {
					RoundComplete = true;
					
					LastVIP = CurrentVIP;
					
					CS_TerminateRound(5.0, CSRoundEnd_CTWin);
					
					PrintToChatAll("%s", "[GO:VIP] The VIP has been rescued, Counter-Terrorists win.");
					
					break;
				}
			}
		}
	}
	
	return Plugin_Continue;
}

public Action:OnTakeDamage(victim, &attacker, &inflictor, &Float:damage, &damagetype)
{
	if (!RoundComplete || victim != CurrentVIP || victim == attacker || victim == inflictor) {
		return Plugin_Continue; /* We don't care! */
	}
	
	return Plugin_Handled;
}

public Action:OnWeaponCanUse(client, weapon) {
	if(CurrentState != VIPState_Playing || client != CurrentVIP) {
		return Plugin_Continue;
	}
	
	new String:entityClassName[256];
	
	GetEntityClassname(weapon, entityClassName, sizeof(entityClassName));
	
	new String:VIPWeapon[256];
	GetConVarString(CVarVIPWeapon, VIPWeapon, sizeof(VIPWeapon));
	 
	if(StrEqual(entityClassName, "weapon_knife", false) || StrEqual(entityClassName, VIPWeapon, false)) {
		return Plugin_Continue;
	}
	
	return Plugin_Handled;
}

public Action:Command_JoinTeam(client, const String:command[], argc)  {
	if(CurrentState != VIPState_Playing || client != CurrentVIP) {
		return Plugin_Continue;
	}
	
	PrintToChat(client, "%s", "[GO:VIP] You are not allowed to change teams while you are the VIP.");
	return Plugin_Handled;
}

bool:IsValidPlayer(client) {
	if(!IsValidEntity(client) || !IsClientConnected(client) || !IsClientInGame(client)) {
		return false;
	}
	
	return true;
}

ProcessConfigurationFiles()
{
	decl String:buffer[512];
	ClearArray(RescueZones);
	
	if (!GetCurrentMap(buffer, sizeof(buffer)))
	{
		return; /* Should never happen... We should maybe even throw an error. */
	}
	
	new Handle:kv = CreateKeyValues("RescueZones");
	
	decl String:path[1024];
	BuildPath(Path_SM, path, sizeof(path), "configs/rescue_zones.cfg");
	
	FileToKeyValues(kv, path);
	
	if(KvJumpToKey(kv, buffer)) {
		KvGotoFirstSubKey(kv);
		
		do {
			new Float:radius = KvGetFloat(kv, "radius", 200.0);
		
			KvGetString(kv, "coords", buffer, sizeof(buffer));
			new String:coords[3][128];
			ExplodeString(buffer, " ", coords, 3, 128);

			PrintToServer("[GO:VIP] Loading rescue zone at [%s, %s, %s] with radius of %f units.", coords[0], coords[1], coords[2], radius);
						
			new Handle:rescueZone = CreateArray();
			PushArrayCell(rescueZone, radius);
			PushArrayCell(rescueZone, StringToFloat(coords[0]));
			PushArrayCell(rescueZone, StringToFloat(coords[1]));
			PushArrayCell(rescueZone, StringToFloat(coords[2]));
			
			PushArrayCell(RescueZones, rescueZone);
		} while (KvGotoNextKey(kv));
	}	
	
	CloseHandle(kv);
}

GetRandomPlayerOnTeam(team, ignore = 0) {
	new teamClientCount = GetTeamClientCount(team);
	
	if(teamClientCount <= 0) {
		return 0;
	}
	
	new client;
	
	do {
		client = GetRandomInt(1, MaxClients);
	} while((teamClientCount > 1 && client == ignore) || !IsClientInGame(client) || GetClientTeam(client) != team);
	
	return client;
}

stock RemoveMapObj() {
	decl String:Class[65];
	new maxent = GetEntityCount();	/* This isn't what you think it is.
									* This function will return the highest edict index in use on the server,
									* not the true number of active entities.
									*/
								
	for (new i=MaxClients;i<maxent;i++) {
		if(!IsValidEdict(i) || !IsValidEntity(i)) {
			continue;
		}
		
		if(GetEdictClassname(i, Class, sizeof(Class)) \
			&& StrContains("func_bomb_target_hostage_entity_func_hostage_rescue",Class) != -1) {
			AcceptEntityInput(i, "Kill");
		}
	}
}


StripWeapons(client) {
	new weaponID;
	
	for(new x = 0; x < 20; x = (x + 4)) {
		weaponID = GetEntDataEnt2(client, MyWeaponsOffset + x);
		
		if(weaponID <= 0) {
			continue;
		}
		
		new String:weaponClassName[128];
		GetEntityClassname(weaponID, weaponClassName, sizeof(weaponClassName));
		
		if(StrEqual(weaponClassName, "weapon_knife", false)) {
			continue;
		}
		
		RemovePlayerItem(client, weaponID);
		RemoveEdict(weaponID);
	}
}

public TouchRescueZone(trigger, client) {
	if(!IsValidPlayer(client)) {
		return;
	} 
	
	if(CurrentState != VIPState_Playing || client != CurrentVIP || RoundComplete) {
		return;
	}
	
	RoundComplete = true;
	
	CS_TerminateRound(5.0, CSRoundEnd_CTWin);
	
	LastVIP = CurrentVIP;
	
	PrintToChatAll("[GO:VIP] The VIP has been rescued, Counter-Terrorists win.");
}