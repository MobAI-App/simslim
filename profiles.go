package main

import "sort"

// Category groups launchd daemon labels that a slim boot disables together.
type Category struct {
	ID             string   `json:"id"`
	Name           string   `json:"name"`
	Description    string   `json:"description"`
	Downside       string   `json:"downside"`
	ApproxMemoryMB int      `json:"approxMemoryMB"`
	Labels         []string `json:"labels"`
}

// Categories is the complete allowlist of disable-safe daemons. A label that
// is not in some category here is never disabled or re-enabled, which is what
// keeps deadlock-inducing daemons (see forbiddenLabels in profiles_test.go)
// permanently out of reach. ApproxMemoryMB is the rounded median increase in
// phys_footprint when only that category is kept on versus a fully slim iOS
// 26.5 clean boot. The estimates vary by runtime and workload and are not
// additive.
var Categories = []Category{
	{
		ID:             "widgets",
		Name:           "Widgets & Wallpaper",
		Description:    "Home and lock screen posters, widgets, and Live Activities.",
		Downside:       "Home and Lock Screen widgets, wallpaper posters, and Live Activities stop updating.",
		ApproxMemoryMB: 675,
		Labels: []string{
			"com.apple.PosterBoard",
			"com.apple.chronod",
			"com.apple.liveactivitiesd",
		},
	},
	{
		ID:             "siri",
		Name:           "Siri & Intelligence",
		Description:    "Siri, Apple Intelligence, speech, and on-device ML model services.",
		Downside:       "Siri, speech features, and Apple Intelligence services are unavailable.",
		ApproxMemoryMB: 265,
		Labels: []string{
			"com.apple.assistantd",
			"com.apple.assistant_cdmd",
			"com.apple.assistant_service",
			"com.apple.siriactionsd",
			"com.apple.siriinferenced",
			"com.apple.siriknowledged",
			"com.apple.sirittsd",
			"com.apple.siri.context.service",
			"com.apple.siri.acousticsignature",
			"com.apple.corespeechd",
			"com.apple.voiced",
			"com.apple.voicebankingd",
			"com.apple.speechmodeltrainingd",
			"com.apple.intelligenceplatformd",
			"com.apple.intelligencecontextd",
			"com.apple.intelligenceflowd",
			"com.apple.intelligencetasksd",
			"com.apple.generativeexperiencesd",
			"com.apple.knowledgeconstructiond",
			"com.apple.naturallanguaged",
			"com.apple.textunderstandingd",
			"com.apple.modelcatalogd",
			"com.apple.modelmanagerd",
			"com.apple.mlhostd",
			"com.apple.mlruntimed",
			"com.apple.suggestd",
			"com.apple.parsecd",
			"com.apple.parsec-fbf",
			"com.apple.proactiveeventtrackerd",
		},
	},
	{
		ID:             "search",
		Name:           "Spotlight & Search",
		Description:    "On-device Spotlight and in-Settings search services.",
		Downside:       "Spotlight and Settings search return no results.",
		ApproxMemoryMB: 50,
		Labels: []string{
			"com.apple.searchd",
			"com.apple.searchtoold",
			"com.apple.spotlightknowledged",
			"com.apple.spotlightknowledged.updater",
			"com.apple.corespotlightservice",
		},
	},
	{
		ID:             "icloud",
		Name:           "iCloud & Apple Account",
		Description:    "iCloud sync, Apple Account, keychain, and backup services.",
		Downside:       "iCloud sync, Apple Account, Keychain, and backup workflows will not work.",
		ApproxMemoryMB: 100,
		Labels: []string{
			"com.apple.appleaccountd",
			"com.apple.appleaccounttransparencyd",
			"com.apple.appleidsetupd",
			"com.apple.akd",
			"com.apple.amsaccountsd",
			"com.apple.amsengagementd",
			"com.apple.amsondevicestoraged",
			"com.apple.cloudd",
			"com.apple.cloudphotod",
			"com.apple.ckdiscretionaryd",
			"com.apple.cloudsettingssyncagent",
			"com.apple.bird",
			"com.apple.syncdefaultsd",
			"com.apple.cdpd",
			"com.apple.sosd",
			"com.apple.SecureBackupDaemon",
			"com.apple.TrustedPeersHelper",
			"com.apple.protectedcloudstorage.protectedcloudkeysyncing",
			"com.apple.icloudmailagent",
			"com.apple.icloudsubscriptionoptimizerd",
			"com.apple.communicationtrustd",
		},
	},
	{
		ID:             "store",
		Name:           "App Store, Push & Media",
		Description:    "App Store, push notification, StoreKit, and media services.",
		Downside:       "Remote push notifications and StoreKit or App Store testing will not work.",
		ApproxMemoryMB: 80,
		Labels: []string{
			"com.apple.appstored",
			"com.apple.appstorecomponentsd",
			"com.apple.apsd",
			"com.apple.itunescloudd",
			"com.apple.itunesstored",
			"com.apple.storekitd",
			"com.apple.videosubscriptionsd",
			"com.apple.assetsubscriptiond",
			"com.apple.musicd",
		},
	},
	{
		ID:             "pim",
		Name:           "Mail, Calendar & Contacts",
		Description:    "Mail, Calendar, Contacts, Reminders, and related sync services.",
		Downside:       "Contacts, Calendar, Reminders, and Mail-backed pickers or sync may fail.",
		ApproxMemoryMB: 80,
		Labels: []string{
			"com.apple.email.maild",
			"com.apple.exchangesyncd",
			"com.apple.dataaccess.dataaccessd",
			"com.apple.calaccessd",
			"com.apple.remindd",
			"com.apple.contactsd",
			"com.apple.contacts.postersyncd",
			"com.apple.peopled",
		},
	},
	{
		ID:             "web",
		Name:           "Safari Sync & Web Services",
		Description:    "Safari sync, web push, privacy, and universal-link services.",
		Downside:       "Universal links and Safari sync or background web services will not work.",
		ApproxMemoryMB: 50,
		Labels: []string{
			"com.apple.SafariBookmarksSyncAgent",
			"com.apple.Safari.History",
			"com.apple.Safari.passwordbreachd",
			"com.apple.Safari.SafeBrowsing.Service",
			"com.apple.safarifetcherd",
			"com.apple.WebBookmarks.webbookmarksd",
			"com.apple.webkit.adattributiond",
			"com.apple.webkit.webpushd",
			"com.apple.webprivacyd",
			"com.apple.swcd",
		},
	},
	{
		ID:             "family",
		Name:           "Family & Screen Time",
		Description:    "Family Sharing, Screen Time, and usage tracking.",
		Downside:       "Family Sharing, Screen Time, and usage tracking stop working.",
		ApproxMemoryMB: 65,
		Labels: []string{
			"com.apple.familycircled",
			"com.apple.FamilyControlsAgent",
			"com.apple.familynotification",
			"com.apple.askpermissiond",
			"com.apple.asktod",
			"com.apple.ScreenTimeAgent",
			"com.apple.ScreenTimeSettingsAgent",
			"com.apple.UsageTrackingAgent",
		},
	},
	{
		ID:             "health",
		Name:           "Health, Home & Fitness",
		Description:    "HealthKit, HomeKit, and Fitness services.",
		Downside:       "HealthKit, HomeKit, and Fitness integrations will not work.",
		ApproxMemoryMB: 135,
		Labels: []string{
			"com.apple.healthd",
			"com.apple.healthappd",
			"com.apple.healthcontentd",
			"com.apple.healtheventsd",
			"com.apple.healthrecordsd",
			"com.apple.finhealthd",
			"com.apple.homed",
			"com.apple.homeeventsd",
			"com.apple.fitcore",
			"com.apple.fitcore.session",
			"com.apple.fitnesscoachingd",
			"com.apple.fitnessintelligenced",
			"com.apple.activityawardsd",
			"com.apple.activitysharingd",
		},
	},
	{
		ID:             "photos",
		Name:           "Photos & Media Analysis",
		Description:    "Photos library, photo analysis, and media analysis services.",
		Downside:       "Photo picker, Photos-library workflows, and media analysis may fail.",
		ApproxMemoryMB: 60,
		Labels: []string{
			"com.apple.photoanalysisd",
			"com.apple.photosface",
			"com.apple.mediaanalysisd",
			"com.apple.mediaanalysisd.service",
			"com.apple.mediastream.mstreamd",
			"com.apple.medialibraryd",
			"com.apple.assetsd",
			"com.apple.assetsd.nebulad",
		},
	},
	{
		ID:             "apps",
		Name:           "News, Weather, Maps & Games",
		Description:    "News, Weather, Maps, Tips, and game services.",
		Downside:       "News, Weather, Maps background data, and game-controller services are unavailable.",
		ApproxMemoryMB: 90,
		Labels: []string{
			"com.apple.newsd",
			"com.apple.weatherd",
			"com.apple.Maps.mapssyncd",
			"com.apple.Maps.mapspushd",
			"com.apple.Maps.geocorrectiond",
			"com.apple.maps.destinationd",
			"com.apple.MapKit.SnapshotService",
			"com.apple.jetpackassetd",
			"com.apple.tipsd",
			"com.apple.gamed",
			"com.apple.gamesaved",
			"com.apple.GameController.gamecontrollerd",
		},
	},
	{
		ID:             "messaging",
		Name:           "Messaging & FaceTime",
		Description:    "iMessage, FaceTime, call, and identity services.",
		Downside:       "iMessage, FaceTime, and related identity services will not work.",
		ApproxMemoryMB: 60,
		Labels: []string{
			"com.apple.identityservicesd",
			"com.apple.ids_simd",
			"com.apple.imautomatichistorydeletionagent",
			"com.apple.imcore.imtransferagent",
			"com.apple.imdpersistence.IMDPersistenceAgent",
			"com.apple.facetimemessagestored",
			"com.apple.telephonyutilities.callservicesd",
		},
	},
	{
		ID:             "connectivity",
		Name:           "Sharing & Device Connectivity",
		Description:    "AirDrop, Continuity, CarPlay, Watch, and Find My services.",
		Downside:       "AirDrop, Continuity, CarPlay, Watch, and Find My connectivity will not work.",
		ApproxMemoryMB: 85,
		Labels: []string{
			"com.apple.sharingd",
			"com.apple.rapportd",
			"com.apple.companiond",
			"com.apple.carkitd",
			"com.apple.wcd",
			"com.apple.tvremoted",
			"com.apple.avatarsd",
			"com.apple.stickersd",
			"com.apple.sociallayerd",
			"com.apple.announced",
			"com.apple.navd",
			"com.apple.findmy.findmylocated",
		},
	},
	{
		ID:             "telemetry",
		Name:           "Ads, Diagnostics & Telemetry",
		Description:    "DeviceCheck, ad privacy, analytics, diagnostics, and feedback services.",
		Downside:       "DeviceCheck plus analytics, diagnostics, and feedback services are unavailable.",
		ApproxMemoryMB: 105,
		Labels: []string{
			"com.apple.ap.adprivacyd",
			"com.apple.ap.promotedcontentd",
			"com.apple.diagnosticextensionsd",
			"com.apple.feedbackd",
			"com.apple.rtcreportingd",
			"com.apple.securityuploadd",
			"com.apple.geoanalyticsd",
			"com.apple.triald",
			"com.apple.followupd",
			"com.apple.purplebuddy.budd",
			"com.apple.devicecheckd",
		},
	},
	{
		ID:             "other",
		Name:           "Other Background Services",
		Description:    "Wallet, business services, assets, and miscellaneous background daemons.",
		Downside:       "Wallet, merchant, business, asset, and miscellaneous background services are unavailable.",
		ApproxMemoryMB: 195,
		Labels: []string{
			"com.apple.financed",
			"com.apple.passd",
			"com.apple.merchantd",
			"com.apple.coreidvd",
			"com.apple.businessservicesd",
			"com.apple.deviceaccessd",
			"com.apple.replicatord",
			"com.apple.linkd",
			"com.apple.ind",
			"com.apple.storagedatad",
			"com.apple.StatusKitAgent",
			"com.apple.countryd",
			"com.apple.mobileassetd",
			"com.apple.managedconfiguration.passcodenagd",
		},
	},
}

func categoryByID(id string) (Category, bool) {
	for _, c := range Categories {
		if c.ID == id {
			return c, true
		}
	}
	return Category{}, false
}

// managedSet is every label under management: the only labels that may ever be
// disabled or re-enabled. Everything else on the device is left untouched.
func managedSet() map[string]bool {
	set := make(map[string]bool)
	for _, c := range Categories {
		for _, l := range c.Labels {
			set[l] = true
		}
	}
	return set
}

// Profile selects which managed daemons a slim boot should disable.
type Profile struct {
	ExceptCategories map[string]bool // category IDs to leave fully enabled
	Keep             map[string]bool // individual labels to leave enabled
}

// desired returns the labels this profile wants disabled.
func (p Profile) desired() map[string]bool {
	set := make(map[string]bool)
	for _, c := range Categories {
		if p.ExceptCategories[c.ID] {
			continue
		}
		for _, l := range c.Labels {
			if p.Keep[l] {
				continue
			}
			set[l] = true
		}
	}
	return set
}

// delta returns the launchctl transitions to move from current to desired,
// scoped to managed labels. Labels outside managed are never touched: a
// non-managed desired label is ignored, and a non-managed label that is already
// disabled is left disabled. Empty results mean the device is already correct.
func delta(current, desired, managed map[string]bool) (toDisable, toEnable []string) {
	dis := map[string]bool{}
	for l := range desired {
		if managed[l] && !current[l] {
			dis[l] = true
		}
	}
	en := map[string]bool{}
	for l := range current {
		if managed[l] && !desired[l] {
			en[l] = true
		}
	}
	return keys(dis), keys(en)
}

func keys(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
