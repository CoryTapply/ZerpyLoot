--[[
About settings page: a short description of the addon plus a list of its
features, one line on what each one does.

Full-width, hand-built content (not page:Section()'s 2-column grid, and not
page:ComingSoon()'s single static line) - same "manual frame +
contentBottomOverride" pattern General.lua's Sounds section and
LootResponses.lua's whole body use, with a layout() function re-run via
page:AddLayoutHook so the wrapped intro/feature-description FontStrings
below get a correct GetStringHeight() once this client's fonts/geometry have
actually settled (see Registry.LayoutCurrentPage) instead of the short
first-pass measurement wrapped text is prone to here.
]]

local FL = ForeverLoot;
local Colors = FL.UI.Colors;
local Sizes = FL.UI.Sizes;
local SetFont = FL.UI.SetFont;

local SECTION_GAP = Sizes.layout.sectionGap;
local ROW_GAP = Sizes.layout.rowGap;
local TITLE_DESC_GAP = 2; -- between a feature's title and its own description
local FEATURE_GAP = 10; -- between one feature's block and the next

local INTRO = "ForeverLoot is a Gargul-compatible roll-off and soft-reserve " ..
    "tracking companion. It runs alongside your raid's existing loot rules, " ..
    "keeping rolls, reserves, council votes, and awards organized without " ..
    "asking anyone to change how they loot.";

local FEATURES = {
    {
        title = "Roll-Offs",
        desc = "Alt+left-click a bag item to start a Gargul-compatible roll-off. Every /roll result is tracked and sorted automatically, with soft-reserved rolls called out.",
    },
    {
        title = "Soft-Reserves",
        desc = "Import a softres.it \"Gargul Export\" sheet and broadcast it to the raid. Raiders can whisper !sr to get their own reserves back, no addon required on their end.",
    },
    {
        title = "Group Loot Tracking",
        desc = "Watches the raid's native Need/Greed/Pass rolls and shows who rolled what, right alongside everything else this addon tracks.",
    },
    {
        title = "Automatic Rolls",
        desc = "Auto-responds to native Group Loot prompts (Need/Greed/Pass) using per-item rules you configure, so routine drops don't need a click.",
    },
    {
        title = "Loot Council",
        desc = "Broadcast a session's item list to the raid, collect every raider's response, and let your council vote and award items from one window.",
    },
    {
        title = "Custom Loot Responses",
        desc = "Build your own set of response buttons (beyond plain Need/Pass) for raiders to pick from when a loot council session asks them to respond.",
    },
    {
        title = "Trade Automation",
        desc = "Opens a trade with the winner and places the awarded item in it automatically once an item is awarded.",
    },
    {
        title = "Loot Chat & History",
        desc = "Prints clean \"X receives loot: [item]\" lines to chat for notable drops, and keeps a persistent history of every council award.",
    },
    {
        title = "Announcements",
        desc = "Choose which of the addon's own raid/party/whisper chat messages get sent, and which stay quiet.",
    },
};

FL.UI.SettingsWindow.RegisterPage("about", "About", function(page)
    page:Header("About");

    local intro = page.frame:CreateFontString(nil, "OVERLAY");
    SetFont(intro, "body");
    intro:SetJustifyH("LEFT");
    intro:SetJustifyV("TOP");
    intro:SetWidth(page.contentWidth);
    intro:SetText(INTRO);
    intro:SetTextColor(unpack(Colors.description));

    local featuresTitle = page.frame:CreateFontString(nil, "OVERLAY");
    SetFont(featuresTitle, "sectionHeader");
    featuresTitle:SetTextColor(unpack(Colors.gold));
    featuresTitle:SetText("Features");

    local divider = page.frame:CreateTexture(nil, "ARTWORK");
    divider:SetColorTexture(unpack(Colors.divider));
    divider:SetHeight(FL.Pixel.PixelSize(1));

    local rows = {};
    for _, feature in ipairs(FEATURES) do
        local title = page.frame:CreateFontString(nil, "OVERLAY");
        SetFont(title, "body");
        title:SetJustifyH("LEFT");
        title:SetText(feature.title);
        title:SetTextColor(unpack(Colors.text));

        local desc = page.frame:CreateFontString(nil, "OVERLAY");
        SetFont(desc, "small");
        desc:SetJustifyH("LEFT");
        desc:SetJustifyV("TOP");
        desc:SetWidth(page.contentWidth);
        desc:SetText(feature.desc);
        desc:SetTextColor(unpack(Colors.muted));

        table.insert(rows, { title = title, desc = desc });
    end

    local function layout()
        local top = page.contentTop;

        intro:ClearAllPoints();
        intro:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, top);
        top = top - intro:GetStringHeight() - SECTION_GAP;

        featuresTitle:ClearAllPoints();
        featuresTitle:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, top);

        divider:ClearAllPoints();
        divider:SetPoint("TOPLEFT", featuresTitle, "BOTTOMLEFT", 0, -6);
        divider:SetPoint("TOPRIGHT", page.frame, "TOPRIGHT", 0, 0);

        top = top - (featuresTitle:GetStringHeight() + 6 + ROW_GAP);

        for _, row in ipairs(rows) do
            row.title:ClearAllPoints();
            row.title:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, top);
            top = top - (row.title:GetStringHeight() + TITLE_DESC_GAP);

            row.desc:ClearAllPoints();
            row.desc:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, top);
            top = top - row.desc:GetStringHeight() - FEATURE_GAP;
        end

        page.contentBottomOverride = top;
    end

    layout();
    page:AddLayoutHook(layout);
end, 70, { footer = false });
