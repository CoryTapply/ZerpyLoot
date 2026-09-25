--[[
General settings page: window-management options. Currently just Reset
Window Positions, moved here unchanged from the old ConfigWindow.
]]

local FL = ForeverLoot;

FL.UI.SettingsWindow.RegisterPage("general", "General", function(page)
    page:Header("General");

    local section = page:Section("Windows", 1);
    section:Button{
        label = "Reset Window Positions",
        width = 200,
        onClick = function()
            if (FL.ResetAllWindowPositions) then
                FL.ResetAllWindowPositions();
                print("|cff8865ffForeverLoot|r window positions reset to default.");
            end
        end,
    };

    -- No opts.footer passed to RegisterPage below - this page gets the
    -- default footer (just "Changes save automatically"; no Reset button
    -- since it has no persisted keys of its own to reset).
end, 10);
