package simslim

import (
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
)

// launchd_sim is a host process, so a simulator's launchd disable overrides are
// not in the device's data directory: they live in the same per-device host
// directory as its launchd.log, keyed only by UDID. launchd_sim reads the file
// when it starts and rewrites it on every `launchctl disable`/`enable`, which is
// why the overrides survive `simctl erase` but not `simctl clone`.
//
// disabledStoreRoot is a var so tests can redirect it away from the real host path.
var disabledStoreRoot = "/private/var/tmp"

func disabledStoreDir(udid string) string {
	return filepath.Join(disabledStoreRoot, "com.apple.CoreSimulator.SimDevice."+udid)
}

func disabledStorePath(udid string) string {
	return filepath.Join(disabledStoreDir(udid), "disabled.plist")
}

// readDisabledStore returns the labels the store marks disabled, mirroring
// readDisabled's contract: a label absent from the result is enabled. A device
// that has never booted has no store, which is the same thing as nothing
// disabled, so a missing file is not an error.
func readDisabledStore(udid string) (map[string]bool, error) {
	entries, err := readStoreEntries(udid)
	if err != nil {
		return nil, err
	}
	disabled := map[string]bool{}
	for label, off := range entries {
		if off {
			disabled[label] = true
		}
	}
	return disabled, nil
}

// readStoreEntries returns every entry verbatim, including the explicit
// false (enabled) entries the runtime writes for itself, which a merge must
// preserve.
func readStoreEntries(udid string) (map[string]bool, error) {
	f, err := os.Open(disabledStorePath(udid))
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]bool{}, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return parseStoreEntries(f)
}

// writeDisabledStore merges the transitions into the store, leaving every other
// entry exactly as it was: the runtime writes its own explicit-enable entries
// here, and labels outside the managed set are never simslim's business. The
// write is atomic so launchd_sim can never read a half-written store.
func writeDisabledStore(udid string, toDisable, toEnable []string) error {
	entries, err := readStoreEntries(udid)
	if err != nil {
		return err
	}
	for _, label := range toDisable {
		entries[label] = true
	}
	for _, label := range toEnable {
		entries[label] = false
	}
	dir := disabledStoreDir(udid)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create launchd disable store: %w", err)
	}
	temp, err := os.CreateTemp(dir, "disabled.plist.*")
	if err != nil {
		return fmt.Errorf("write launchd disable store: %w", err)
	}
	defer os.Remove(temp.Name())
	if _, err := temp.Write(encodeStoreEntries(entries)); err != nil {
		temp.Close()
		return fmt.Errorf("write launchd disable store: %w", err)
	}
	if err := temp.Close(); err != nil {
		return fmt.Errorf("write launchd disable store: %w", err)
	}
	if err := os.Chmod(temp.Name(), 0o644); err != nil {
		return fmt.Errorf("write launchd disable store: %w", err)
	}
	if err := os.Rename(temp.Name(), disabledStorePath(udid)); err != nil {
		return fmt.Errorf("write launchd disable store: %w", err)
	}
	return nil
}

// encodeStoreEntries renders the store in the same XML plist shape launchd_sim
// writes, sorted so a rewrite that changes nothing produces an identical file.
func encodeStoreEntries(entries map[string]bool) []byte {
	var b bytes.Buffer
	b.WriteString(xml.Header)
	b.WriteString("<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n")
	b.WriteString("<plist version=\"1.0\">\n<dict>\n")
	for _, label := range sortedKeys(entries) {
		b.WriteString("\t<key>")
		xml.EscapeText(&b, []byte(label))
		b.WriteString("</key>\n\t<")
		if entries[label] {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
		b.WriteString("/>\n")
	}
	b.WriteString("</dict>\n</plist>\n")
	return b.Bytes()
}

func sortedKeys(entries map[string]bool) []string {
	labels := make([]string, 0, len(entries))
	for label := range entries {
		labels = append(labels, label)
	}
	sort.Strings(labels)
	return labels
}

// parseStoreEntries reads the flat <key>label</key><true/>|<false/> dict that
// launchd_sim writes. Anything else in the file is ignored rather than rejected,
// so an unexpected value type cannot make the store unreadable.
func parseStoreEntries(r io.Reader) (map[string]bool, error) {
	entries := map[string]bool{}
	decoder := xml.NewDecoder(r)
	label := ""
	for {
		token, err := decoder.Token()
		if errors.Is(err, io.EOF) {
			return entries, nil
		}
		if err != nil {
			return nil, fmt.Errorf("parse launchd disable store: %w", err)
		}
		start, ok := token.(xml.StartElement)
		if !ok {
			continue
		}
		switch start.Name.Local {
		case "key":
			var text string
			if err := decoder.DecodeElement(&text, &start); err != nil {
				return nil, fmt.Errorf("parse launchd disable store: %w", err)
			}
			label = text
		case "true", "false":
			if label != "" {
				entries[label] = start.Name.Local == "true"
				label = ""
			}
		}
	}
}
