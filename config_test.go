// config_test.go
package main

import (
	"encoding/json"
	"testing"
	"time"
)

func TestConfigDefaults(t *testing.T) {
	cfg := defaultConfig()
	if cfg.ListInterval != 30*time.Minute {
		t.Errorf("ListInterval want 30m got %v", cfg.ListInterval)
	}
	if cfg.BuyInterval != 5*time.Minute {
		t.Errorf("BuyInterval want 5m got %v", cfg.BuyInterval)
	}
	if cfg.ListingsPerGrade != 5 {
		t.Errorf("ListingsPerGrade want 5 got %d", cfg.ListingsPerGrade)
	}
	if cfg.BuyThreshold != 1.05 {
		t.Errorf("BuyThreshold want 1.05 got %f", cfg.BuyThreshold)
	}
	if cfg.MaxBuys != 50 {
		t.Errorf("MaxBuys want 50 got %d", cfg.MaxBuys)
	}
	if !cfg.Enabled {
		t.Error("Enabled should default to true")
	}
	if len(cfg.GradeMultipliers) != 6 {
		t.Errorf("GradeMultipliers want len 6 got %d", len(cfg.GradeMultipliers))
	}
}

func TestConfigSnapshot(t *testing.T) {
	c := &Config{}
	c.config = defaultConfig()
	snap := c.Snapshot()
	snap.MaxBuys = 999
	if c.config.MaxBuys == 999 {
		t.Error("Snapshot should be a copy, not a reference")
	}
}

func TestConfigUpdate(t *testing.T) {
	c := &Config{}
	c.config = defaultConfig()

	patch := map[string]json.RawMessage{}
	b, _ := json.Marshal(25)
	patch["max_buys"] = b
	if err := c.Apply(patch); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if c.Snapshot().MaxBuys != 25 {
		t.Error("MaxBuys not updated")
	}
}

func TestConfigValidation(t *testing.T) {
	c := &Config{}
	c.config = defaultConfig()

	patch := map[string]json.RawMessage{}
	b, _ := json.Marshal(-1)
	patch["max_buys"] = b
	if err := c.Apply(patch); err == nil {
		t.Error("expected error for negative MaxBuys")
	}
}
