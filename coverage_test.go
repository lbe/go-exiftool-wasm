package exiftool

import (
	"testing"
)

func TestCommandArgsDefault(t *testing.T) {
	savedExec, savedArg1, savedConfig := Exec, Arg1, Config
	defer func() { Exec, Arg1, Config = savedExec, savedArg1, savedConfig }()

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
	savedExec, savedArg1, savedConfig := Exec, Arg1, Config
	defer func() { Exec, Arg1, Config = savedExec, savedArg1, savedConfig }()

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
	savedExec, savedArg1, savedConfig := Exec, Arg1, Config
	defer func() { Exec, Arg1, Config = savedExec, savedArg1, savedConfig }()

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
	savedExec, savedArg1, savedConfig := Exec, Arg1, Config
	defer func() { Exec, Arg1, Config = savedExec, savedArg1, savedConfig }()

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
