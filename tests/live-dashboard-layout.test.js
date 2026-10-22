'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { runAddon } = require('./helpers/lua');

test('sidebar measures complete wrapped text after first layout, quest changes, and resizing', () => {
	const [out] = runAddon({
		stubs: ['stub_ui.lua', 'live-dashboard.lua'],
		addons: [{ name: 'Polestar', files: [
			'Core/Core.xml', 'Theme/Theme.xml', 'UI/UI.lua', 'UI/LiveCharacter.lua', 'UI/LiveDashboard.lua',
		] }],
		script: `
			uistub.install(); livestub.install(); stub.login()
			uistub.setGuide(uistub.elwynn, 3)
			-- The client measures only visible lines inside a fixed-height
			-- FontString. The general UI stub otherwise ignores that constraint.
			local naturalHeight = stub.Methods.GetStringHeight
			stub.Methods.GetStringHeight = function(self)
				local h, fixed = naturalHeight(self), self.height or 0
				return fixed > 0 and math.min(h, fixed) or h
			end
			local snapshot = {
				hearth = { have = true, ready = true, bind = "Dolanaar" },
				questLogAvailable = true, questCount = 1, questMax = 20,
				quests = {{ title = "Zenn's Bidding", objectives = {
					{ text = "0/3 Nightsaber Fang", cur = 0, max = 3 },
					{ text = "Strigid Owl Feather", cur = 0, max = 3 },
					{ text = "Webwood Spider Silk", cur = 0, max = 3 },
				} }},
				items = {}, itemsAvailable = true, travel = "On foot",
			}
			PolestarPlanner.LiveCharacter.GetSnapshot = function() return snapshot end
			local D = PolestarPlanner.LiveDashboard
			UIParent:SetSize(1920, 1080)
			D.Show()
			local F = D.GetFrame()
			local function measure()
				local result = {}
				for name, fs in pairs({ facts = F.CharacterFacts, quests = F.CharacterExtra, goals = F.DetailText }) do
					result[name] = { height = fs:GetHeight(), natural = naturalHeight(fs), width = fs:GetWidth() }
				end
				return result
			end
			local initial = measure()
			local initialText = F.CharacterExtra:GetText()
			snapshot.quests[2] = { title = "Crown of the Earth", objectives = {
				{ text = "Fill the Jade Phial at the Starbreeze Village moonwell", cur = 0, max = 1 },
			} }
			D.Refresh(true)
			local grown = measure()
			F:SetSize(900, 650); stub.RunScript(F, "OnSizeChanged", 900, 650); D.Refresh(true)
			local narrow = measure()
			snapshot.quests = {}; D.Refresh(true)
			local smaller = measure()
			emit({ initialText=initialText, initial = initial, grown = grown, narrow = narrow, smaller = smaller })
		`,
	}).emitted;
	assert.match(out.initialText, /0\/3 Nightsaber Fang/);
	assert.doesNotMatch(out.initialText, /Nightsaber Fang  0\/3/);
	for (const phase of [out.initial,out.grown,out.narrow,out.smaller]) {
		for (const block of Object.values(phase)) {
			assert.ok(block.height >= block.natural, `text height ${block.height} clips ${block.natural}`);
		}
	}
	assert.ok(out.initial.facts.height >= 48, 'all four character facts are visible on first open');
	assert.ok(out.initial.quests.height > 80, 'quest objectives are visible below the heading');
	assert.ok(out.grown.quests.height > out.initial.quests.height, 'new quests expand the text block');
	assert.ok(out.narrow.quests.width < out.grown.quests.width);
	assert.ok(out.narrow.goals.height > out.grown.goals.height, 'narrower text reflows instead of clipping');
	assert.ok(out.smaller.quests.height < out.narrow.quests.height, 'removed quests release the old height');
});
