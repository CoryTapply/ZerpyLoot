--[[
Announcements settings page - not implemented yet.
]]

local FL = ForeverLoot;

FL.UI.SettingsWindow.RegisterPage("announcements", "Announcements", function(page)
    page:Header("Announcements");
    page:ComingSoon();
end, 50, { footer = false });
