-- Finestra del DMG "dockduo" montato in /Volumes/dockduo (make dmg): vista a icone da 128, sfondo, posizioni.
-- La prima volta macOS chiede a chi lancia make il permesso di controllare il Finder (Automazione).
tell application "Finder"
	tell disk "dockduo"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 120, 840, 548}
		set opts to the icon view options of container window
		set arrangement of opts to not arranged
		set icon size of opts to 128
		set text size of opts to 13
		set background picture of opts to file ".background:background.png"
		set position of item "dockduo.app" of container window to {160, 180}
		set position of item "Applications" of container window to {480, 180}
		update without registering applications
		delay 1
		close
	end tell
end tell
