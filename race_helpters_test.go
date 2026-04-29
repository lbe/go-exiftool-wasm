package exiftool

import "testing"

var raceEnabled = false

func skipSlowRaceTest(t *testing.T) {
	t.Helper()
	if raceEnabled {
		t.Skip("skipping slow integration test under -race")
	}
}
