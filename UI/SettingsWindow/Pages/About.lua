--[[
About settings page - not implemented yet.
]]

local FL = ForeverLoot;

FL.UI.SettingsWindow.RegisterPage("about", "About", function(page)
    page:Header("About");
    page:ComingSoon();
end, 70, { footer = false });
