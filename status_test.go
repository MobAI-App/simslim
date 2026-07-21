package main

import "testing"

func TestDroppedCategories(t *testing.T) {
	search, ok := categoryByID("search")
	if !ok {
		t.Fatal("search category not found")
	}
	disabled := map[string]bool{
		search.Labels[0]:            true,
		search.Labels[1]:            true,
		"com.apple.assistantd":      true,
		"com.apple.not-a-managed-d": true,
	}

	got := droppedCategories(disabled)

	byID := map[string]DroppedCategory{}
	for _, c := range got {
		byID[c.ID] = c
	}
	if len(got) != 2 {
		t.Fatalf("dropped categories = %d, want 2 (search, siri)", len(got))
	}
	if labels := byID["search"].Labels; len(labels) != 2 {
		t.Errorf("search dropped labels = %v, want 2", labels)
	}
	if labels := byID["siri"].Labels; len(labels) != 1 || labels[0] != "com.apple.assistantd" {
		t.Errorf("siri dropped labels = %v, want [com.apple.assistantd]", labels)
	}
	for _, c := range got {
		if c.Downside == "" {
			t.Errorf("dropped category %q has no downside", c.ID)
		}
	}
}

func TestDroppedCategoriesEmpty(t *testing.T) {
	if got := droppedCategories(map[string]bool{}); len(got) != 0 {
		t.Errorf("droppedCategories(stock) = %v, want empty", got)
	}
}
