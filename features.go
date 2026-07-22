package main

import "fmt"

// Feature is a user-facing capability backed by specific launchd daemons.
// Every label must also live in a Category (enforced in features_test.go), so a
// feature only ever names daemons the tool could actually have turned off.
type Feature struct {
	ID     string   `json:"id"`
	Name   string   `json:"name"`
	Labels []string `json:"labels"`
}

// Features maps commonly required capabilities to the daemons they need running.
var Features = []Feature{
	{ID: "push", Name: "Push notifications", Labels: []string{"com.apple.apsd"}},
	{ID: "storekit", Name: "StoreKit / in-app purchase", Labels: []string{"com.apple.storekitd"}},
	{ID: "app-store", Name: "App Store", Labels: []string{"com.apple.appstored", "com.apple.itunesstored"}},
	{ID: "universal-links", Name: "Universal links / associated domains", Labels: []string{"com.apple.swcd"}},
	{ID: "spotlight", Name: "Spotlight & Settings search", Labels: []string{"com.apple.searchd", "com.apple.searchtoold"}},
	{ID: "siri", Name: "Siri & speech", Labels: []string{"com.apple.assistantd", "com.apple.corespeechd"}},
	{ID: "icloud", Name: "iCloud sync", Labels: []string{"com.apple.cloudd"}},
	{ID: "keychain-sync", Name: "iCloud Keychain", Labels: []string{"com.apple.akd"}},
	{ID: "contacts", Name: "Contacts", Labels: []string{"com.apple.contactsd"}},
	{ID: "calendar", Name: "Calendar", Labels: []string{"com.apple.calaccessd"}},
	{ID: "reminders", Name: "Reminders", Labels: []string{"com.apple.remindd"}},
	{ID: "mail", Name: "Mail", Labels: []string{"com.apple.email.maild"}},
	{ID: "photos", Name: "Photos library & analysis", Labels: []string{"com.apple.assetsd", "com.apple.photoanalysisd"}},
	{ID: "health", Name: "HealthKit", Labels: []string{"com.apple.healthd"}},
	{ID: "homekit", Name: "HomeKit", Labels: []string{"com.apple.homed"}},
	{ID: "imessage", Name: "iMessage & FaceTime", Labels: []string{"com.apple.identityservicesd"}},
	{ID: "widgets", Name: "Widgets & Live Activities", Labels: []string{"com.apple.chronod", "com.apple.liveactivitiesd"}},
	{ID: "wallet", Name: "Wallet & passes", Labels: []string{"com.apple.passd"}},
	{ID: "maps", Name: "Maps background services", Labels: []string{"com.apple.Maps.mapssyncd"}},
	{ID: "weather", Name: "Weather", Labels: []string{"com.apple.weatherd"}},
	{ID: "news", Name: "News", Labels: []string{"com.apple.newsd"}},
	{ID: "game-center", Name: "Game Center", Labels: []string{"com.apple.gamed"}},
	{ID: "find-my", Name: "Find My", Labels: []string{"com.apple.findmy.findmylocated"}},
	{ID: "screen-time", Name: "Screen Time", Labels: []string{"com.apple.ScreenTimeAgent"}},
}

func featureByID(id string) (Feature, bool) {
	for _, f := range Features {
		if f.ID == id {
			return f, true
		}
	}
	return Feature{}, false
}

// resolveFeatures maps requested IDs to their Features, erroring on the first
// unknown one so a typo in --requires fails loudly instead of passing silently.
func resolveFeatures(ids []string) ([]Feature, error) {
	out := make([]Feature, 0, len(ids))
	for _, id := range ids {
		f, ok := featureByID(id)
		if !ok {
			return nil, fmt.Errorf("unknown feature %q (see `simslim doctor --list`)", id)
		}
		out = append(out, f)
	}
	return out, nil
}

// diagnoseFeatures reports, for each feature, which of its daemons the device
// currently has disabled. A feature is OK only when none of them are.
func diagnoseFeatures(features []Feature, disabled map[string]bool) DoctorOutput {
	statuses := make([]FeatureStatus, 0, len(features))
	allOK := true
	for _, f := range features {
		var down []string
		for _, l := range f.Labels {
			if disabled[l] {
				down = append(down, l)
			}
		}
		ok := len(down) == 0
		allOK = allOK && ok
		statuses = append(statuses, FeatureStatus{ID: f.ID, Name: f.Name, OK: ok, Disabled: down})
	}
	return DoctorOutput{OK: allOK, Features: statuses}
}
