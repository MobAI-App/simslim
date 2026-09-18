package simslim

import (
	"os"
	"path/filepath"
	"testing"
)

// storeFixture is the shape launchd_sim writes: a flat dict of label to bool,
// where true means disabled and false means an explicit enable.
const storeFixture = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.assistantd</key>
	<true/>
	<key>com.apple.nanonewscd</key>
	<false/>
	<key>com.apple.tipsd</key>
	<true/>
</dict>
</plist>
`

func TestReadDisabledStoreParsesLaunchdPlist(t *testing.T) {
	udid := "00000000-0000-0000-0000-0000000000AA"
	seedStore(t, udid, storeFixture)

	got, err := readDisabledStore(udid)
	if err != nil {
		t.Fatalf("readDisabledStore: %v", err)
	}
	want := map[string]bool{"com.apple.assistantd": true, "com.apple.tipsd": true}
	if len(got) != len(want) {
		t.Fatalf("readDisabledStore() = %v, want %v", got, want)
	}
	for label := range want {
		if !got[label] {
			t.Errorf("label %q not reported as disabled", label)
		}
	}
}

func TestWriteDisabledStorePreservesEntriesItDoesNotOwn(t *testing.T) {
	udid := "00000000-0000-0000-0000-0000000000BB"
	seedStore(t, udid, `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>com.apple.assistantd</key>
	<true/>
	<key>com.apple.nanonewscd</key>
	<false/>
	<key>com.example.unmanaged</key>
	<true/>
</dict>
</plist>
`)

	if err := writeDisabledStore(udid, []string{"com.apple.tipsd"}, []string{"com.apple.assistantd"}); err != nil {
		t.Fatalf("writeDisabledStore: %v", err)
	}

	got, err := readStoreEntries(udid)
	if err != nil {
		t.Fatalf("readStoreEntries: %v", err)
	}
	want := map[string]bool{
		"com.apple.tipsd":       true,  // newly disabled
		"com.apple.assistantd":  false, // re-enabled
		"com.apple.nanonewscd":  false, // the runtime's own entry, untouched
		"com.example.unmanaged": true,  // never simslim's business, untouched
	}
	if len(got) != len(want) {
		t.Fatalf("store entries = %v, want %v", got, want)
	}
	for label, off := range want {
		if got[label] != off {
			t.Errorf("entry %q = %t, want %t", label, got[label], off)
		}
	}
}

func TestWriteDisabledStoreSeedsANeverBootedDevice(t *testing.T) {
	udid := "00000000-0000-0000-0000-0000000000CC"
	useTempStoreRoot(t)

	if err := writeDisabledStore(udid, []string{"com.apple.tipsd"}, nil); err != nil {
		t.Fatalf("writeDisabledStore: %v", err)
	}

	disabled, err := readDisabledStore(udid)
	if err != nil {
		t.Fatalf("readDisabledStore: %v", err)
	}
	if !disabled["com.apple.tipsd"] {
		t.Errorf("seeded store = %v, want com.apple.tipsd disabled", disabled)
	}
	info, err := os.Stat(disabledStoreDir(udid))
	if err != nil {
		t.Fatalf("stat store dir: %v", err)
	}
	if got := info.Mode().Perm(); got != 0o700 {
		t.Errorf("store dir mode = %o, want 700 to match CoreSimulator", got)
	}
}

func TestReadDisabledStoreTreatsAMissingStoreAsNothingDisabled(t *testing.T) {
	useTempStoreRoot(t)

	disabled, err := readDisabledStore("00000000-0000-0000-0000-0000000000DD")
	if err != nil {
		t.Fatalf("readDisabledStore on a never-booted device: %v", err)
	}
	if len(disabled) != 0 {
		t.Errorf("readDisabledStore() = %v, want empty", disabled)
	}
}

// useTempStoreRoot redirects the store root at a temp dir for the test's lifetime.
func useTempStoreRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	orig := disabledStoreRoot
	disabledStoreRoot = root
	t.Cleanup(func() { disabledStoreRoot = orig })
	return root
}

// seedStore points the store root at a temp dir and writes raw contents for udid.
func seedStore(t *testing.T, udid, contents string) string {
	t.Helper()
	root := useTempStoreRoot(t)
	dir := filepath.Join(root, "com.apple.CoreSimulator.SimDevice."+udid)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "disabled.plist")
	if contents != "" {
		if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return path
}
