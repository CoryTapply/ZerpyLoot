--[[
Loot Rolls settings page: the Group Loot popup-replacement/lock checkboxes,
moved here unchanged from the old ConfigWindow (same saved keys, same
reload-required/live-apply behavior).
]]

local FL = ForeverLoot;

FL.UI.SettingsWindow.RegisterPage("lootrolls", "Loot Rolls", function(page)
    page:Header("Loot Rolls");

    local section = page:Section("Roll Popup", 1);

    section:Checkbox{
        key = "loot.replacePopup",
        label = "Replace default Group Loot popup (Need/Greed/Pass)",
        tooltip = "Requires /reload to take effect.",
        default = true,
    };

    section:Checkbox{
        key = "loot.lockRolls",
        label = "Lock Group Loot rolls (hide header)",
        desc = "Hides the drag header so rolls can't be moved.",
        default = false,
        onChange = function()
            if (FL.UI.GroupLootRollBars and FL.UI.GroupLootRollBars.RefreshLock) then
                FL.UI.GroupLootRollBars.RefreshLock();
            end
        end,
    };

    -- Example of a child option, indented and disabled while its parent is
    -- unchecked - not a real setting, just the pattern to copy:
    -- section:Checkbox{
    --     key = "loot.lockRolls.exampleChild",
    --     label = "Example child option",
    --     parent = "loot.lockRolls",
    --     default = false,
    -- };
end, 30);
