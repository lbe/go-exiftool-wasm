//go:build race

package exiftool

func init() {
	raceEnabled = true
}
