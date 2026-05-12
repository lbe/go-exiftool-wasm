package exiftool

import "runtime"

func init() {
	if runtime.GOOS == "windows" {
		Exec = `dist\exiftool.exe`
	} else {
		Exec = "dist/exiftool"
	}
}
