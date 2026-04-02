tell application "Terminal"
	activate
	do script "cd \"$(dirname \"$0\")\"; ./run.sh"
end tell