package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// errWizardCancelled signals the user quit the builder; callers exit cleanly.
var errWizardCancelled = errors.New("cancelled")

// SlimProfile is the on-disk profile applied with `simslim on --profile <path>`.
// Except and Keep mirror the `--except` and `--keep` flags.
type SlimProfile struct {
	Name        string   `json:"name,omitempty"`
	Description string   `json:"description,omitempty"`
	Except      []string `json:"except,omitempty"`
	Keep        []string `json:"keep,omitempty"`
}

// loadSlimProfile reads a profile file and resolves it to a validated Profile.
func loadSlimProfile(path string) (Profile, error) {
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
		if _, ok := categoryByID(id); !ok {
			return Profile{}, fmt.Errorf("profile %s: unknown category %q (see `simslim profiles`)", path, id)
		}
		p.ExceptCategories[id] = true
	}
	slimmable := slimmableSet()
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

// buildProfile selects the slim profile for an `on` invocation. A --profile
// file is the single source of truth, so it cannot be combined with
// --except/--keep.
func buildProfile(profilePath, except, keep string) (Profile, error) {
	if profilePath != "" {
		if except != "" || keep != "" {
			return Profile{}, fmt.Errorf("--profile cannot be combined with --except or --keep")
		}
		return loadSlimProfile(profilePath)
	}
	p := Profile{ExceptCategories: map[string]bool{}, Keep: map[string]bool{}}
	for _, id := range splitList(except) {
		if _, ok := categoryByID(id); !ok {
			return Profile{}, fmt.Errorf("unknown category %q (see `simslim profiles`)", id)
		}
		p.ExceptCategories[id] = true
	}
	for _, l := range splitList(keep) {
		p.Keep[l] = true
	}
	return p, nil
}

// marshalProfile renders a profile as indented JSON with a trailing newline.
func marshalProfile(sp SlimProfile) ([]byte, error) {
	data, err := json.MarshalIndent(sp, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}

// profileFileName derives a JSON filename from a profile name, for when the
// command targets a directory. Non-filename runs collapse to a hyphen; an empty
// name falls back to profile.json.
func profileFileName(name string) string {
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

// stdinIsTerminal reports whether stdin is an interactive terminal.
func stdinIsTerminal() bool {
	fi, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

// enterRawMode puts the terminal into raw, no-echo mode on the alternate screen
// so the selector can read keystrokes and own the display. It returns the row
// count and a restore func. It uses stty to avoid a terminal-handling dependency.
func enterRawMode() (func(), int, error) {
	stty := func(args ...string) *exec.Cmd {
		c := exec.Command("stty", args...)
		c.Stdin = os.Stdin
		return c
	}
	saved, err := stty("-g").Output()
	if err != nil {
		return nil, 0, fmt.Errorf("read terminal state: %w", err)
	}
	rows := terminalRows(stty)
	if err := stty("raw", "-echo").Run(); err != nil {
		return nil, 0, fmt.Errorf("enter raw mode: %w", err)
	}
	fmt.Fprint(os.Stderr, "\x1b[?1049h\x1b[?25l") // alternate screen + hide cursor
	return func() {
		fmt.Fprint(os.Stderr, "\x1b[?25h\x1b[?1049l") // restore cursor + primary screen
		_ = stty(strings.TrimSpace(string(saved))).Run()
	}, rows, nil
}

// terminalRows reports the terminal height, defaulting to 24.
func terminalRows(stty func(...string) *exec.Cmd) int {
	out, err := stty("size").Output()
	if err != nil {
		return 24
	}
	fields := strings.Fields(string(out))
	if len(fields) == 0 {
		return 24
	}
	n, err := strconv.Atoi(fields[0])
	if err != nil || n < 6 {
		return 24
	}
	return n
}

// runProfileWizard interactively assembles a SlimProfile. Prompts go to out,
// kept off stdout so the JSON stays redirectable. enterRaw switches the terminal
// into per-keystroke mode and reports its height (a no-op in tests).
func runProfileWizard(in io.Reader, out io.Writer, enterRaw func() (func(), int, error)) (SlimProfile, error) {
	r := bufio.NewReader(in)
	readLine := func(label string) string {
		fmt.Fprint(out, label)
		line, _ := r.ReadString('\n')
		return strings.TrimSpace(line)
	}

	fmt.Fprintln(out, "Create a slim profile.")
	fmt.Fprintln(out)
	name := readLine("Name (optional): ")
	description := readLine("Description (optional): ")

	restore, rows, err := enterRaw()
	if err != nil {
		return SlimProfile{}, err
	}
	defer restore()

	except, keep, cancelled := selectProfile(r, out, rows)
	if cancelled {
		return SlimProfile{}, errWizardCancelled
	}

	// Catalog order, and drop keeps inside an enabled feature (redundant).
	var exceptIDs, keptLabels []string
	for _, c := range Categories {
		if except[c.ID] {
			exceptIDs = append(exceptIDs, c.ID)
			continue
		}
		for _, l := range c.Labels {
			if keep[l] {
				keptLabels = append(keptLabels, l)
			}
		}
	}
	return SlimProfile{Name: name, Description: description, Except: exceptIDs, Keep: keptLabels}, nil
}

// key is a normalized keystroke from readKey.
type key int

const (
	keyOther key = iota
	keyUp
	keyDown
	keyLeft
	keyRight
	keyEnter
	keySpace
	keyRune
	keyCancel // Ctrl-C
)

// readKey reads one keystroke, decoding arrow sequences. The rune is set for keyRune.
func readKey(r *bufio.Reader) (key, rune) {
	b, err := r.ReadByte()
	if err != nil {
		return keyCancel, 0
	}
	switch b {
	case '\r', '\n':
		return keyEnter, 0
	case ' ':
		return keySpace, 0
	case 3: // Ctrl-C
		return keyCancel, 0
	case 0x1b: // arrow keys arrive as ESC [ A/B/C/D
		if b1, err := r.ReadByte(); err != nil || b1 != '[' {
			return keyOther, 0
		}
		switch b2, _ := r.ReadByte(); b2 {
		case 'A':
			return keyUp, 0
		case 'B':
			return keyDown, 0
		case 'C':
			return keyRight, 0
		case 'D':
			return keyLeft, 0
		}
		return keyOther, 0
	default:
		return keyRune, rune(b)
	}
}

// selectProfile runs the feature checklist: space keeps a whole feature, → drills
// into its daemons. Returns the chosen Except and Keep sets. See the footer for keys.
func selectProfile(r *bufio.Reader, out io.Writer, termRows int) (except, keep map[string]bool, cancelled bool) {
	except = map[string]bool{}
	keep = map[string]bool{}
	header := []string{
		"Features to keep enabled — everything unchecked is slimmed.",
		"[x] whole feature kept · [~] some daemons kept",
	}
	footer := "↑/↓ move · space keep feature · → pick daemons · a all · n none · enter save · q cancel"
	visible := viewportRows(termRows, len(header))
	cursor, top := 0, 0
	for {
		rows := categoryRows(except, keep)
		top = windowTop(top, cursor, visible, len(rows))
		drawChecklist(out, header, rows, footer, cursor, top, visible)
		k, ch := readKey(r)
		switch {
		case k == keyUp, k == keyRune && ch == 'k':
			cursor = clampCursor(cursor-1, len(rows))
		case k == keyDown, k == keyRune && ch == 'j':
			cursor = clampCursor(cursor+1, len(rows))
		case k == keyEnter:
			return except, keep, false
		case k == keyCancel, k == keyRune && (ch == 'q' || ch == 'Q'):
			return nil, nil, true
		case k == keySpace:
			toggleMember(except, Categories[cursor].ID)
		case k == keyRight, k == keyRune && ch == 'l':
			if selectDaemons(r, out, Categories[cursor], keep, termRows) {
				return nil, nil, true
			}
		case k == keyRune && (ch == 'a' || ch == 'A'):
			for _, c := range Categories {
				except[c.ID] = true
			}
		case k == keyRune && (ch == 'n' || ch == 'N'):
			for id := range except {
				delete(except, id)
			}
		}
	}
}

// selectDaemons runs one feature's daemon checklist, mutating keep in place. ←/h
// returns to the feature list; Ctrl-C aborts the whole wizard (via cancelled).
func selectDaemons(r *bufio.Reader, out io.Writer, c Category, keep map[string]bool, termRows int) (cancelled bool) {
	header := []string{
		c.Name + " — keep individual daemons enabled.",
		"Unchecked daemons in this feature are slimmed.",
	}
	footer := "↑/↓ move · space keep daemon · a all · n none · ← back · q cancel"
	visible := viewportRows(termRows, len(header))
	cursor, top := 0, 0
	for {
		rows := daemonRows(c, keep)
		top = windowTop(top, cursor, visible, len(rows))
		drawChecklist(out, header, rows, footer, cursor, top, visible)
		k, ch := readKey(r)
		switch {
		case k == keyUp, k == keyRune && ch == 'k':
			cursor = clampCursor(cursor-1, len(rows))
		case k == keyDown, k == keyRune && ch == 'j':
			cursor = clampCursor(cursor+1, len(rows))
		case k == keyLeft, k == keyEnter, k == keyRune && (ch == 'h' || ch == 'q' || ch == 'Q'):
			return false
		case k == keyCancel:
			return true
		case k == keySpace:
			toggleMember(keep, c.Labels[cursor])
		case k == keyRune && (ch == 'a' || ch == 'A'):
			for _, l := range c.Labels {
				keep[l] = true
			}
		case k == keyRune && (ch == 'n' || ch == 'N'):
			for _, l := range c.Labels {
				delete(keep, l)
			}
		}
	}
}

// categoryRows renders the feature list. Marker: [x] fully kept, [~] some daemons
// kept, [ ] slimmed.
func categoryRows(except, keep map[string]bool) []string {
	rows := make([]string, len(Categories))
	for i, c := range Categories {
		box := "[ ]"
		suffix := ""
		switch {
		case except[c.ID]:
			box = "[x]"
		default:
			if n := categoryKeepCount(c, keep); n > 0 {
				box = "[~]"
				suffix = fmt.Sprintf("  (%d kept)", n)
			}
		}
		rows[i] = fmt.Sprintf("%s %-14s %s%s", box, c.ID, c.Name, suffix)
	}
	return rows
}

// daemonRows renders one feature's daemons with a [x]/[ ] keep marker.
func daemonRows(c Category, keep map[string]bool) []string {
	rows := make([]string, len(c.Labels))
	for i, l := range c.Labels {
		box := "[ ]"
		if keep[l] {
			box = "[x]"
		}
		line := fmt.Sprintf("%s %s", box, l)
		if desc := c.ServiceDescriptions[l]; desc != "" {
			line = fmt.Sprintf("%s %-44s %s", box, l, desc)
		}
		rows[i] = truncate(line, 76)
	}
	return rows
}

func categoryKeepCount(c Category, keep map[string]bool) int {
	n := 0
	for _, l := range c.Labels {
		if keep[l] {
			n++
		}
	}
	return n
}

// drawChecklist repaints the screen: header, a windowed slice of rows with a ❯
// cursor, and a footer. It clears first, so each call fully replaces the frame.
func drawChecklist(out io.Writer, header, rows []string, footer string, cursor, top, visible int) {
	fmt.Fprint(out, "\x1b[H\x1b[J") // home + clear to end of screen
	for _, h := range header {
		fmt.Fprintf(out, "%s\r\n", h)
	}
	end := top + visible
	if end > len(rows) {
		end = len(rows)
	}
	for i := top; i < end; i++ {
		pointer := "  "
		if i == cursor {
			pointer = "❯ "
		}
		fmt.Fprintf(out, "%s%s\r\n", pointer, rows[i])
	}
	more := ""
	if top > 0 {
		more += " ↑more"
	}
	if end < len(rows) {
		more += " ↓more"
	}
	fmt.Fprintf(out, "\r\n%s%s", footer, more)
}

// viewportRows is how many list rows fit given the terminal height and header.
func viewportRows(termRows, headerLines int) int {
	v := termRows - headerLines - 2 // one blank line + one footer line
	if v < 3 {
		return 3
	}
	return v
}

// windowTop scrolls the viewport so the cursor stays visible.
func windowTop(top, cursor, visible, total int) int {
	if total <= visible {
		return 0
	}
	if cursor < top {
		top = cursor
	}
	if cursor >= top+visible {
		top = cursor - visible + 1
	}
	if top > total-visible {
		top = total - visible
	}
	if top < 0 {
		top = 0
	}
	return top
}

func clampCursor(v, n int) int {
	if v < 0 {
		return 0
	}
	if v > n-1 {
		return n - 1
	}
	return v
}

func toggleMember(set map[string]bool, key string) {
	if set[key] {
		delete(set, key)
	} else {
		set[key] = true
	}
}
