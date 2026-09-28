package main

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func fakeCommand(t *testing.T, body string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell fixture runs on POSIX CI")
	}
	path := filepath.Join(t.TempDir(), "fake-command")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestNeedsLeaseForSelectedDevice(t *testing.T) {
	real := fakeCommand(t, `printf 'List of devices attached\nUSB123 device model:Pixel_8 transport_id:7\nemulator-5554 device model:sdk_gphone64 transport_id:8\n'`)
	cfg := config{RealADB: real, Serials: []string{"USB123"}, Models: []string{"Pixel_8"}}
	tests := []struct {
		name string
		args []string
		want bool
	}{
		{"explicit serial", []string{"-s", "USB123", "shell", "true"}, true},
		{"model from connected devices", []string{"shell", "true"}, true},
		{"transport ID", []string{"-t", "7", "shell", "true"}, true},
		{"known connect", []string{"connect", "USB123"}, true},
		{"emulator serial", []string{"-s", "emulator-5554", "shell", "true"}, false},
		{"emulator flag", []string{"-e", "shell", "true"}, false},
		{"device listing", []string{"devices", "-l"}, false},
		{"version", []string{"version"}, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := needsLease(cfg, tc.args)
			if err != nil || got != tc.want {
				t.Fatalf("needsLease(%v) = %v, %v; want %v", tc.args, got, err, tc.want)
			}
		})
	}
}

func TestCheckLeaseAcceptsOneResponseAndClosesChild(t *testing.T) {
	checker := fakeCommand(t, `printf '{"status":"valid"}\n'; exec sleep 30`)
	cfg := config{LeaseCommand: []string{checker}, IDEnv: "ADB_LEASE_ID"}
	start := time.Now()
	if err := checkLease(cfg, "current-id"); err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("lease response took %s; child was not closed", elapsed)
	}
}

func TestCheckLeaseRejectsWrongID(t *testing.T) {
	checker := fakeCommand(t, `printf '{"status":"invalid_lease"}\n'`)
	cfg := config{LeaseCommand: []string{checker}, IDEnv: "ADB_LEASE_ID"}
	if err := checkLease(cfg, "wrong-id"); err == nil {
		t.Fatal("wrong ID was accepted")
	}
}
