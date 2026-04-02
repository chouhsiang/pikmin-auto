set appPath to POSIX path of (path to me)
set resourcesPath to appPath & "Contents/Resources"

tell application "Terminal"
	activate
	do script "cd " & quoted form of resourcesPath & "; ./launcher.sh"
end tell
