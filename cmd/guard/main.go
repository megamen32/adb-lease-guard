// adb-lease-guard forwards ADB to the original binary after checking a shared lease.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	busy    = 75
	invalid = 70
)

type config struct {
	RealADB      string   `json:"real_adb"`
	LeaseCommand []string `json:"lease_command"`
	Serials      []string `json:"device_serials"`
	Models       []string `json:"device_models"`
	IDEnv        string   `json:"id_env"`
}

func loadConfig() (config, error) {
	path := os.Getenv("ADB_LEASE_CONFIG")
	if path == "" {
		executable, err := os.Executable()
		if err != nil {
			return config{}, err
		}
		path = filepath.Join(filepath.Dir(executable), "adb-lease.json")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return config{}, fmt.Errorf("read %s: %w", path, err)
	}
	var cfg config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return config{}, fmt.Errorf("parse %s: %w", path, err)
	}
	if cfg.RealADB == "" || len(cfg.LeaseCommand) == 0 ||
		len(cfg.Serials)+len(cfg.Models) == 0 {
		return config{}, errors.New("config requires real_adb, lease_command, and device_serials or device_models")
	}
	if !filepath.IsAbs(cfg.RealADB) {
		cfg.RealADB = filepath.Join(filepath.Dir(path), cfg.RealADB)
	}
	if cfg.IDEnv == "" {
		cfg.IDEnv = "ADB_LEASE_ID"
	}
	return cfg, nil
}

func member(value string, set []string) bool {
	for _, item := range set {
		if value == item {
			return true
		}
	}
	return false
}

func target(args []string) (serial, transport, action string, extra []string, emulator bool) {
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-s", "-t", "-H", "-P", "-L":
			if i+1 < len(args) {
				if args[i] == "-s" {
					serial = args[i+1]
				}
				if args[i] == "-t" {
					transport = args[i+1]
				}
				i++
			}
		case "-e":
			emulator = true
		case "-d", "-a", "-l":
			// ADB global flags without values.
		default:
			if strings.HasPrefix(args[i], "-") {
				continue
			}
			return serial, transport, args[i], args[i+1:], emulator
		}
	}
	return
}

func deviceLines(real string) ([]string, error) {
	output, err := exec.Command(real, "devices", "-l").Output()
	if err != nil {
		return nil, err
	}
	return strings.Split(string(output), "\n"), nil
}

func matchingDevice(cfg config, line string) (string, bool) {
	fields := strings.Fields(line)
	if len(fields) < 2 || fields[0] == "List" {
		return "", false
	}
	if member(fields[0], cfg.Serials) {
		return fields[0], true
	}
	for _, field := range fields[2:] {
		if strings.HasPrefix(field, "model:") && member(strings.TrimPrefix(field, "model:"), cfg.Models) {
			return fields[0], true
		}
	}
	return "", false
}

func needsLease(cfg config, args []string) (bool, error) {
	serial, transport, action, extra, emulator := target(args)
	if emulator || strings.HasPrefix(serial, "emulator-") {
		return false, nil
	}
	switch action {
	case "", "help", "version", "devices", "start-server":
		return false, nil
	case "connect", "disconnect":
		if len(extra) > 0 && member(extra[0], cfg.Serials) {
			return true, nil
		}
	}
	if member(serial, cfg.Serials) {
		return true, nil
	}
	lines, err := deviceLines(cfg.RealADB)
	if err != nil {
		return false, fmt.Errorf("identify connected devices: %w", err)
	}
	for _, line := range lines {
		deviceSerial, matches := matchingDevice(cfg, line)
		if matches && ((serial == "" && transport == "") || serial == deviceSerial ||
			(transport != "" && strings.Contains(line, "transport_id:"+transport))) {
			return true, nil
		}
	}
	return false, nil
}

func checkLease(cfg config, id string) error {
	if id == "" {
		return fmt.Errorf("%s is missing; acquire the device lease first", cfg.IDEnv)
	}
	if strings.ContainsAny(id, " \t\r\n") {
		return errors.New("lease ID is malformed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	args := append(append([]string{}, cfg.LeaseCommand[1:]...), "check", id)
	cmd := exec.CommandContext(ctx, cfg.LeaseCommand[0], args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	line, readErr := bufio.NewReader(stdout).ReadString('\n')
	// Some Windows SSH clients keep a completed remote session open. The one
	// JSON line is the complete result, so close that client after reading it.
	_ = cmd.Process.Kill()
	_ = cmd.Wait()
	if readErr != nil && readErr != io.EOF {
		return fmt.Errorf("lease check read failed: %w", readErr)
	}
	var response struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal([]byte(line), &response); err != nil || response.Status != "valid" {
		return fmt.Errorf("lease check denied: %s %s", strings.TrimSpace(line), strings.TrimSpace(stderr.String()))
	}
	return nil
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		fmt.Fprintln(os.Stderr, "adb-lease:", err)
		os.Exit(invalid)
	}
	realInfo, err := os.Stat(cfg.RealADB)
	if err != nil {
		fmt.Fprintln(os.Stderr, "adb-lease: original adb unavailable:", err)
		os.Exit(invalid)
	}
	if executable, err := os.Executable(); err == nil {
		if selfInfo, err := os.Stat(executable); err == nil && os.SameFile(realInfo, selfInfo) {
			fmt.Fprintln(os.Stderr, "adb-lease: real_adb points back to the guard")
			os.Exit(invalid)
		}
	}
	gate, err := needsLease(cfg, os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "adb-lease:", err)
		os.Exit(invalid)
	}
	if gate {
		if err := checkLease(cfg, os.Getenv(cfg.IDEnv)); err != nil {
			fmt.Fprintln(os.Stderr, "adb-lease:", err)
			os.Exit(busy)
		}
	}
	cmd := exec.Command(cfg.RealADB, os.Args[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		if exit, ok := err.(*exec.ExitError); ok {
			os.Exit(exit.ExitCode())
		}
		fmt.Fprintln(os.Stderr, "adb-lease:", err)
		os.Exit(invalid)
	}
}
