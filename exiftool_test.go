package exiftool

import (
	"runtime"
	"testing"
)

func TestCommandArgsDefault(t *testing.T) {
	savedArg1, savedConfig := Arg1, Config
	defer func() { Arg1, Config = savedArg1, savedConfig }()

	Arg1 = ""
	Config = ""

	args := commandArgs([]string{"-ver"})
	if len(args) != 3 {
		t.Fatalf("expected 3 args, got %d: %v", len(args), args)
	}
	if args[0] != "-charset" {
		t.Errorf("expected -charset, got %q", args[0])
	}
	if args[1] != "filename=utf8" {
		t.Errorf("expected filename=utf8, got %q", args[1])
	}
	if args[2] != "-ver" {
		t.Errorf("expected -ver, got %q", args[2])
	}
}

func TestCommandArgsWithArg1(t *testing.T) {
	savedArg1, savedConfig := Arg1, Config
	defer func() { Arg1, Config = savedArg1, savedConfig }()

	Arg1 = "/usr/bin/perl"
	Config = ""

	args := commandArgs([]string{"-ver"})
	found := false
	for _, a := range args {
		if a == "/usr/bin/perl" {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("expected Arg1 in args, got %v", args)
	}
}

func TestCommandArgsWithConfig(t *testing.T) {
	savedArg1, savedConfig := Arg1, Config
	defer func() { Arg1, Config = savedArg1, savedConfig }()

	Arg1 = ""
	Config = "/path/to/config"

	args := commandArgs([]string{"-ver"})
	foundConfig, foundConfigPath := false, false
	for i, a := range args {
		if a == "-config" {
			foundConfig = true
			if i+1 < len(args) && args[i+1] == "/path/to/config" {
				foundConfigPath = true
			}
		}
	}
	if !foundConfig || !foundConfigPath {
		t.Errorf("expected -config /path/to/config in args, got %v", args)
	}
}

func TestCommandArgsWithBoth(t *testing.T) {
	savedArg1, savedConfig := Arg1, Config
	defer func() { Arg1, Config = savedArg1, savedConfig }()

	Arg1 = "/usr/bin/perl"
	Config = "/path/to/config"

	if commandArgs([]string{"-ver"})[0] != "/usr/bin/perl" {
		t.Errorf("expected Arg1 first")
	}
	args := commandArgs([]string{"-ver"})
	foundConfig := false
	for i, a := range args {
		if a == "-config" && i+1 < len(args) && args[i+1] == "/path/to/config" {
			foundConfig = true
		}
	}
	if !foundConfig {
		t.Errorf("expected -config in args, got %v", args)
	}
}

func TestPerlQuote(t *testing.T) {
	tests := []struct{ in, want string }{
		{"/home/u", `'/home/u'`},
		{"it's", `'it\'s'`},
		{`a\b`, `'a\\b'`},
		{`a\'`, `'a\\\''`},
	}
	for _, tt := range tests {
		if got := perlQuote(tt.in); got != tt.want {
			t.Errorf("perlQuote(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestGuestRoot(t *testing.T) {
	tests := []struct{ cwd, hostRoot, guestCwd string }{
		{"/", "/", "/"},
		{"/home/u", "/", "/home/u"},
		{`/home/it's \dir`, "/", `/home/it's \dir`},
	}
	if runtime.GOOS == "windows" {
		tests = []struct{ cwd, hostRoot, guestCwd string }{
			{`C:\`, `C:\`, "/"},
			{`C:\Users\u`, `C:\`, "/Users/u"},
			{`D:\a\b c`, `D:\`, "/a/b c"},
			{`\\server\share\dir`, `\\server\share\`, "/dir"},
		}
	}
	for _, tt := range tests {
		hostRoot, guestCwd := guestRoot(tt.cwd)
		if hostRoot != tt.hostRoot || guestCwd != tt.guestCwd {
			t.Errorf("guestRoot(%q) = %q, %q, want %q, %q", tt.cwd, hostRoot, guestCwd, tt.hostRoot, tt.guestCwd)
		}
	}
}
