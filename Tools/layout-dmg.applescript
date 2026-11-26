on run arguments
	set mountPath to item 1 of arguments
	set volumeRoot to POSIX file mountPath as alias
	set installerBackground to POSIX file (mountPath & "/.background/background.png") as alias

	with timeout of 30 seconds
		tell application "Finder"
			open volumeRoot
			set installerWindow to container window of volumeRoot
			set installerDisk to target of installerWindow
			set current view of installerWindow to icon view
			set toolbar visible of installerWindow to false
			set statusbar visible of installerWindow to false
			set pathbar visible of installerWindow to false
			set sidebar width of installerWindow to 0
			set bounds of installerWindow to {160, 150, 760, 550}
			tell icon view options of installerWindow
				set arrangement to not arranged
				set icon size to 128
				set shows item info to false
				set label position to bottom
				set background picture to installerBackground
			end tell
			set position of item "Seven.app" of installerDisk to {150, 188}
			set position of item "Applications" of installerDisk to {450, 188}
			close installerWindow
		end tell
	end timeout
end run
