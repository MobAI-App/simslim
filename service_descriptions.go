package main

// serviceDescriptionByLabel gives the GUI a short, user-facing explanation for
// every daemon that can be controlled individually. These descriptions explain
// the service's primary role without implying that private Apple daemons have a
// stable public API or an isolated memory cost.
var serviceDescriptionByLabel = map[string]string{
	// Widgets & Wallpaper
	"com.apple.PosterBoard":     "Renders Home and Lock Screen wallpaper scenes.",
	"com.apple.chronod":         "Refreshes widgets and complications on schedule.",
	"com.apple.liveactivitiesd": "Updates Live Activities and Dynamic Island content.",

	// Siri & Intelligence
	"com.apple.assistantd":             "Coordinates Siri requests and assistant state.",
	"com.apple.assistant_cdmd":         "Routes commands and intents submitted to Siri.",
	"com.apple.assistant_service":      "Provides supporting services for Siri requests.",
	"com.apple.siriactionsd":           "Executes Siri actions and App Intents.",
	"com.apple.siriinferenced":         "Runs Siri inference and intent predictions.",
	"com.apple.siriknowledged":         "Maintains knowledge and context used by Siri.",
	"com.apple.sirittsd":               "Generates Siri's spoken responses.",
	"com.apple.siri.context.service":   "Builds device context for Siri requests.",
	"com.apple.siri.acousticsignature": "Processes acoustic signatures for voice features.",
	"com.apple.corespeechd":            "Provides speech recognition and voice-trigger services.",
	"com.apple.voiced":                 "Manages system voices and speech assets.",
	"com.apple.voicebankingd":          "Supports Personal Voice and voice banking.",
	"com.apple.speechmodeltrainingd":   "Adapts on-device speech recognition models.",
	"com.apple.intelligenceplatformd":  "Coordinates Apple Intelligence services.",
	"com.apple.intelligencecontextd":   "Collects local context for intelligence features.",
	"com.apple.intelligenceflowd":      "Orchestrates Apple Intelligence workflows.",
	"com.apple.intelligencetasksd":     "Runs background Apple Intelligence tasks.",
	"com.apple.generativeexperiencesd": "Supports generative intelligence experiences.",
	"com.apple.knowledgeconstructiond": "Builds on-device knowledge used by suggestions.",
	"com.apple.naturallanguaged":       "Performs natural-language analysis.",
	"com.apple.textunderstandingd":     "Extracts meaning and entities from text.",
	"com.apple.modelcatalogd":          "Tracks machine-learning models available to the system.",
	"com.apple.modelmanagerd":          "Downloads and manages on-device models.",
	"com.apple.mlhostd":                "Hosts system machine-learning services.",
	"com.apple.mlruntimed":             "Executes on-device machine-learning models.",
	"com.apple.suggestd":               "Generates system suggestions and predictions.",
	"com.apple.parsecd":                "Provides network-backed Siri and Spotlight suggestions.",
	"com.apple.parsec-fbf":             "Collects feedback for Siri and Spotlight suggestions.",
	"com.apple.proactiveeventtrackerd": "Tracks events used by proactive suggestions.",

	// Spotlight & Search
	"com.apple.searchd":                     "Coordinates system search queries.",
	"com.apple.searchtoold":                 "Runs helper tasks for system search.",
	"com.apple.spotlightknowledged":         "Builds knowledge used by Spotlight results.",
	"com.apple.spotlightknowledged.updater": "Refreshes Spotlight's knowledge data.",
	"com.apple.corespotlightservice":        "Indexes and searches app-provided content.",

	// iCloud & Apple Account
	"com.apple.appleaccountd":                                  "Maintains Apple Account state on the device.",
	"com.apple.appleaccounttransparencyd":                      "Checks Apple Account security records.",
	"com.apple.appleidsetupd":                                  "Handles Apple Account setup workflows.",
	"com.apple.akd":                                            "Provides Apple Account authentication tokens.",
	"com.apple.amsaccountsd":                                   "Manages App Store and media account state.",
	"com.apple.amsengagementd":                                 "Handles App Store and media engagement messages.",
	"com.apple.amsondevicestoraged":                            "Stores Apple media-service data on the device.",
	"com.apple.cloudd":                                         "Synchronizes CloudKit databases and records.",
	"com.apple.cloudphotod":                                    "Synchronizes the iCloud Photos library.",
	"com.apple.ckdiscretionaryd":                               "Schedules non-urgent CloudKit transfers.",
	"com.apple.cloudsettingssyncagent":                         "Synchronizes supported system settings through iCloud.",
	"com.apple.bird":                                           "Synchronizes iCloud Drive files.",
	"com.apple.syncdefaultsd":                                  "Synchronizes supported preferences between devices.",
	"com.apple.cdpd":                                           "Handles iCloud data-protection setup and recovery.",
	"com.apple.sosd":                                           "Synchronizes iCloud Keychain secure items.",
	"com.apple.SecureBackupDaemon":                             "Handles secure backup and account recovery data.",
	"com.apple.TrustedPeersHelper":                             "Maintains trusted peers for iCloud Keychain.",
	"com.apple.protectedcloudstorage.protectedcloudkeysyncing": "Synchronizes protected cloud encryption keys.",
	"com.apple.icloudmailagent":                                "Runs background services for iCloud Mail.",
	"com.apple.icloudsubscriptionoptimizerd":                   "Evaluates iCloud storage subscription recommendations.",
	"com.apple.communicationtrustd":                            "Maintains communication trust and safety state.",

	// App Store, Push & Media
	"com.apple.appstored":           "Installs and updates apps from the App Store.",
	"com.apple.appstorecomponentsd": "Provides background components used by the App Store.",
	"com.apple.apsd":                "Receives Apple Push Notification service messages.",
	"com.apple.itunescloudd":        "Synchronizes purchased and cloud media libraries.",
	"com.apple.itunesstored":        "Handles media-store accounts and purchases.",
	"com.apple.storekitd":           "Processes StoreKit products and transactions.",
	"com.apple.videosubscriptionsd": "Manages video subscriptions and TV providers.",
	"com.apple.assetsubscriptiond":  "Manages subscribed media assets and downloads.",
	"com.apple.musicd":              "Runs background Music library and playback services.",

	// Mail, Calendar & Contacts
	"com.apple.email.maild":            "Fetches, indexes, and sends Mail account data.",
	"com.apple.exchangesyncd":          "Synchronizes Microsoft Exchange account data.",
	"com.apple.dataaccess.dataaccessd": "Synchronizes CalDAV, CardDAV, and related accounts.",
	"com.apple.calaccessd":             "Provides access to Calendar event data.",
	"com.apple.remindd":                "Stores and synchronizes reminders.",
	"com.apple.contactsd":              "Provides access to the Contacts database.",
	"com.apple.contacts.postersyncd":   "Synchronizes Contact Posters.",
	"com.apple.peopled":                "Builds people and relationship suggestions.",

	// Safari Sync & Web Services
	"com.apple.SafariBookmarksSyncAgent":    "Synchronizes Safari bookmarks through iCloud.",
	"com.apple.Safari.History":              "Maintains and synchronizes Safari history.",
	"com.apple.Safari.passwordbreachd":      "Checks saved passwords for known data leaks.",
	"com.apple.Safari.SafeBrowsing.Service": "Checks sites against unsafe browsing data.",
	"com.apple.safarifetcherd":              "Fetches Safari content in the background.",
	"com.apple.WebBookmarks.webbookmarksd":  "Maintains web bookmarks, clips, and Reading List data.",
	"com.apple.webkit.adattributiond":       "Processes privacy-preserving web ad attribution.",
	"com.apple.webkit.webpushd":             "Receives push notifications for websites.",
	"com.apple.webprivacyd":                 "Maintains Safari privacy-protection data.",
	"com.apple.swcd":                        "Matches universal links with installed apps.",

	// Family & Screen Time
	"com.apple.familycircled":           "Maintains Family Sharing membership and state.",
	"com.apple.FamilyControlsAgent":     "Applies parental and Family Controls restrictions.",
	"com.apple.familynotification":      "Delivers Family Sharing invitations and notices.",
	"com.apple.askpermissiond":          "Handles Ask to Buy permission requests.",
	"com.apple.asktod":                  "Routes family approval prompts and responses.",
	"com.apple.ScreenTimeAgent":         "Enforces Screen Time limits and reports usage.",
	"com.apple.ScreenTimeSettingsAgent": "Connects Screen Time data to Settings.",
	"com.apple.UsageTrackingAgent":      "Tracks app and website usage duration.",

	// Health, Home & Fitness
	"com.apple.healthd":              "Stores and serves HealthKit data.",
	"com.apple.healthappd":           "Runs background tasks for the Health app.",
	"com.apple.healthcontentd":       "Provides educational and recommended health content.",
	"com.apple.healtheventsd":        "Processes health events and related notifications.",
	"com.apple.healthrecordsd":       "Synchronizes clinical health records.",
	"com.apple.finhealthd":           "Analyzes Wallet transactions and financial-health data.",
	"com.apple.homed":                "Manages HomeKit accessories, rooms, and automations.",
	"com.apple.homeeventsd":          "Processes HomeKit events and automation triggers.",
	"com.apple.fitcore":              "Runs Apple Fitness content and background services.",
	"com.apple.fitcore.session":      "Manages active Apple Fitness sessions.",
	"com.apple.fitnesscoachingd":     "Provides Fitness coaching recommendations.",
	"com.apple.fitnessintelligenced": "Generates personalized Fitness insights.",
	"com.apple.activityawardsd":      "Tracks Activity awards and achievements.",
	"com.apple.activitysharingd":     "Synchronizes shared Activity and Fitness data.",

	// Photos & Media Analysis
	"com.apple.photoanalysisd":         "Analyzes photos for scenes, people, and search.",
	"com.apple.photosface":             "Performs face detection for the Photos library.",
	"com.apple.mediaanalysisd":         "Analyzes image, video, and audio content.",
	"com.apple.mediaanalysisd.service": "Runs isolated media-analysis work.",
	"com.apple.mediastream.mstreamd":   "Synchronizes shared and streamed photo content.",
	"com.apple.medialibraryd":          "Maintains the system media library database.",
	"com.apple.assetsd":                "Provides access to Photos library assets.",
	"com.apple.assetsd.nebulad":        "Handles cloud-backed Photos asset transfers.",

	// News, Weather, Maps & Games
	"com.apple.newsd":                          "Downloads and refreshes Apple News content.",
	"com.apple.weatherd":                       "Fetches forecasts and weather data.",
	"com.apple.Maps.mapssyncd":                 "Synchronizes Maps favorites, guides, and history.",
	"com.apple.Maps.mapspushd":                 "Receives background updates for Maps.",
	"com.apple.Maps.geocorrectiond":            "Improves and corrects map location data.",
	"com.apple.maps.destinationd":              "Predicts and maintains suggested destinations.",
	"com.apple.MapKit.SnapshotService":         "Renders static map snapshots for apps.",
	"com.apple.jetpackassetd":                  "Downloads assets used by Apple content apps.",
	"com.apple.tipsd":                          "Selects and refreshes content for the Tips app.",
	"com.apple.gamed":                          "Provides Game Center accounts and multiplayer state.",
	"com.apple.gamesaved":                      "Synchronizes supported game save data.",
	"com.apple.GameController.gamecontrollerd": "Discovers controllers and routes their input.",

	// Messaging & FaceTime
	"com.apple.identityservicesd":                  "Maintains identities used by iMessage and FaceTime.",
	"com.apple.ids_simd":                           "Provides simulator support for Apple identity services.",
	"com.apple.imautomatichistorydeletionagent":    "Removes Messages history according to retention settings.",
	"com.apple.imcore.imtransferagent":             "Transfers Messages attachments and media.",
	"com.apple.imdpersistence.IMDPersistenceAgent": "Stores Messages conversations and metadata.",
	"com.apple.facetimemessagestored":              "Stores FaceTime messages and related data.",
	"com.apple.telephonyutilities.callservicesd":   "Coordinates FaceTime and system call state.",

	// Sharing & Device Connectivity
	"com.apple.rapportd":             "Discovers nearby devices for Continuity features.",
	"com.apple.companiond":           "Coordinates communication with paired companion devices.",
	"com.apple.carkitd":              "Provides CarPlay connection and vehicle services.",
	"com.apple.wcd":                  "Handles connectivity with a paired Apple Watch.",
	"com.apple.tvremoted":            "Provides Apple TV discovery and remote control.",
	"com.apple.avatarsd":             "Maintains avatars and Memoji assets.",
	"com.apple.stickersd":            "Maintains sticker packs and recently used stickers.",
	"com.apple.sociallayerd":         "Supports social sharing and activity features.",
	"com.apple.announced":            "Supports announced notifications and audio messages.",
	"com.apple.navd":                 "Coordinates background navigation state.",
	"com.apple.findmy.findmylocated": "Provides device location data to Find My.",

	// Ads, Diagnostics & Telemetry
	"com.apple.ap.adprivacyd":         "Maintains advertising privacy preferences and state.",
	"com.apple.ap.promotedcontentd":   "Fetches and manages promoted Apple content.",
	"com.apple.diagnosticextensionsd": "Runs system diagnostic data collectors.",
	"com.apple.feedbackd":             "Collects and submits system feedback reports.",
	"com.apple.rtcreportingd":         "Reports diagnostics for real-time communications.",
	"com.apple.securityuploadd":       "Uploads security and trust telemetry.",
	"com.apple.geoanalyticsd":         "Collects Maps and location-quality analytics.",
	"com.apple.triald":                "Manages system feature experiments and configurations.",
	"com.apple.followupd":             "Schedules account and setup follow-up notices.",
	"com.apple.purplebuddy.budd":      "Maintains Setup Assistant completion state.",
	"com.apple.devicecheckd":          "Provides DeviceCheck and app-attestation services.",

	// Other Background Services
	"com.apple.financed":                          "Provides Wallet transaction and finance services.",
	"com.apple.passd":                             "Manages Wallet passes and Apple Pay state.",
	"com.apple.merchantd":                         "Looks up merchant details for Wallet transactions.",
	"com.apple.coreidvd":                          "Manages supported digital identity credentials.",
	"com.apple.businessservicesd":                 "Supports Apple business messaging and services.",
	"com.apple.deviceaccessd":                     "Coordinates app access to supported accessories.",
	"com.apple.replicatord":                       "Replicates supported system data between services.",
	"com.apple.linkd":                             "Indexes App Intents and shortcut suggestions.",
	"com.apple.ind":                               "Receives background iCloud notifications.",
	"com.apple.storagedatad":                      "Calculates storage usage shown by the system.",
	"com.apple.StatusKitAgent":                    "Shares Focus, presence, and status between devices.",
	"com.apple.countryd":                          "Determines regional availability for system features.",
	"com.apple.mobileassetd":                      "Downloads and manages system asset packages.",
	"com.apple.managedconfiguration.passcodenagd": "Enforces managed passcode requirements.",
}

func init() {
	for i := range Categories {
		Categories[i].ServiceDescriptions = make(map[string]string, len(Categories[i].Labels))
		for _, label := range Categories[i].Labels {
			Categories[i].ServiceDescriptions[label] = serviceDescriptionByLabel[label]
		}
	}
}
