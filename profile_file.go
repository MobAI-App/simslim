package simslim

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// SlimProfile is the on-disk profile applied with `simslim on --profile <path>`.
// Except and Keep mirror the `--except` and `--keep` flags.
type SlimProfile struct {
	Name        string   `json:"name,omitempty"`
	Description string   `json:"description,omitempty"`
	Except      []string `json:"except,omitempty"`
	Keep        []string `json:"keep,omitempty"`
}

// loadSlimProfile reads a profile file and resolves it to a validated Profile.
func LoadSlimProfile(path string) (Profile, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Profile{}, fmt.Errorf("read profile %s: %w", path, err)
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var sp SlimProfile
	if err := dec.Decode(&sp); err != nil {
		return Profile{}, fmt.Errorf("parse profile %s: %w", path, err)
	}
	return sp.resolve(path)
}

// resolve turns a parsed SlimProfile into the validated Profile it selects.
func (sp SlimProfile) resolve(path string) (Profile, error) {
	p := Profile{ExceptCategories: map[string]bool{}, Keep: map[string]bool{}}
	for _, id := range sp.Except {
		if id = strings.TrimSpace(id); id == "" {
			continue
		}
		if _, ok := CategoryByID(id); !ok {
			return Profile{}, fmt.Errorf("profile %s: unknown category %q (see `simslim profiles`)", path, id)
		}
		p.ExceptCategories[id] = true
	}
	slimmable := SlimmableSet()
	for _, label := range sp.Keep {
		if label = strings.TrimSpace(label); label == "" {
			continue
		}
		if !slimmable[label] {
			return Profile{}, fmt.Errorf("profile %s: %q is not a daemon any category disables (see `simslim profiles`)", path, label)
		}
		p.Keep[label] = true
	}
	return p, nil
}

// SplitList parses the comma-separated list syntax shared by the --except,
// --keep, --requires and --categories flags, dropping blank entries.
func SplitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// buildProfile selects the slim profile for an `on` invocation. A --profile
// file is the single source of truth, so it cannot be combined with
// --except/--keep.
func BuildProfile(profilePath, except, keep string) (Profile, error) {
	if profilePath != "" {
		if except != "" || keep != "" {
			return Profile{}, fmt.Errorf("--profile cannot be combined with --except or --keep")
		}
		return LoadSlimProfile(profilePath)
	}
	p := Profile{ExceptCategories: map[string]bool{}, Keep: map[string]bool{}}
	for _, id := range SplitList(except) {
		if _, ok := CategoryByID(id); !ok {
			return Profile{}, fmt.Errorf("unknown category %q (see `simslim profiles`)", id)
		}
		p.ExceptCategories[id] = true
	}
	for _, l := range SplitList(keep) {
		p.Keep[l] = true
	}
	return p, nil
}

// marshalProfile renders a profile as indented JSON with a trailing newline.
func MarshalProfile(sp SlimProfile) ([]byte, error) {
	data, err := json.MarshalIndent(sp, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}

// profileFileName derives a JSON filename from a profile name, for when the
// command targets a directory. Non-filename runs collapse to a hyphen; an empty
// name falls back to profile.json.
func ProfileFileName(name string) string {
	var b strings.Builder
	prevDash := false
	for _, r := range strings.ToLower(strings.TrimSpace(name)) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '_', r == '.':
			b.WriteRune(r)
			prevDash = false
		default:
			if !prevDash {
				b.WriteByte('-')
				prevDash = true
			}
		}
	}
	slug := strings.Trim(b.String(), "-.")
	if slug == "" {
		return "profile.json"
	}
	if strings.HasSuffix(slug, ".json") {
		return slug
	}
	return slug + ".json"
}
