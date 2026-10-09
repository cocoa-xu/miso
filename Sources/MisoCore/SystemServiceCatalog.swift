enum SystemServiceCatalog {
  static let features: [String: [String]] = [
    "advertising": [
      "com.apple.ap.adprivacyd", "com.apple.ap.promotedcontentd", "com.apple.tipsd",
      "com.apple.ndoagent", "com.apple.amsengagementd",
    ],
    "siri": [
      "com.apple.siriappintentsd", "com.apple.assistant_service", "com.apple.assistantd",
      "com.apple.SiriTTSTrainingAgent", "com.apple.sirittsd",
      "com.apple.siriinferenced", "com.apple.siriknowledged", "com.apple.assistant_cdmd",
      "com.apple.parsecd", "com.apple.parsec-fbf", "com.apple.siriactionsd",
    ],
    "appleIntelligence": [
      "com.apple.generativeexperiencesd", "com.apple.privatecloudcomputed",
      "com.apple.modelcatalogd", "com.apple.ModelCatalogAgent", "com.apple.modelmanagerd",
      "com.apple.visualintelligenced", "com.apple.GenerativeFunctions.agentstored",
      "com.apple.contextstored", "com.apple.intelligencecontextd",
      "com.apple.intelligenceplatformd", "com.apple.intelligenceflowd",
      "com.apple.intelligencetasksd", "com.apple.callintelligenced",
    ],
    "telemetryUpload": [
      "com.apple.analyticsd", "com.apple.SubmitDiagInfo", "com.apple.diagnosticspushd",
      "com.apple.geoanalyticsd",
      "com.apple.wifianalyticsd",
    ],
    "photoAnalysis": ["com.apple.photoanalysisd", "com.apple.mediaanalysisd"],
    "cloudSync": [
      "com.apple.cloudd", "com.apple.bird", "com.apple.cloudphotod", "com.apple.icloudwebd",
      "com.apple.icloudmailagent", "com.apple.cloudsettingssyncagent", "com.apple.syncdefaultsd",
      "com.apple.iCloudNotificationAgent", "com.apple.iCloudUserNotificationsd",
      "com.apple.SafariBookmarksSyncAgent", "com.apple.AOSPushRelay",
      "com.apple.security.keychain-circle-notification",
    ],
    "messages": [
      "com.apple.imagent", "com.apple.imautomatichistorydeletionagent",
      "com.apple.imcore.imtransferagent", "com.apple.telephonyutilities.callservicesd",
      "com.apple.callhistoryd", "com.apple.CallHistoryPluginHelper",
      "com.apple.CallHistorySyncHelper", "com.apple.businessservicesd",
      "com.apple.facetimemessagestored", "com.apple.CommCenter",
    ],
    "continuity": [
      "com.apple.sharingd", "com.apple.rapportd", "com.apple.nearbyd",
      "com.apple.AirPlayXPCHelper", "com.apple.mediacontinuityd", "com.apple.replicatord",
      "com.apple.sidecar-relay", "com.apple.sidecar-display-agent",
      "com.apple.cmio.ContinuityCaptureAgent", "com.apple.companiond",
    ],
    "home": [
      "com.apple.homed", "com.apple.homeeventsd", "com.apple.threadradiod",
      "com.apple.ThreadCommissionerService", "com.apple.homeenergyd",
    ],
    "personalApps": [
      "com.apple.newsd", "com.apple.weatherd", "com.apple.familycircled",
      "com.apple.contactsd", "com.apple.calaccessd", "com.apple.remindd",
      "com.apple.dataaccess.dataaccessd", "com.apple.email.maild",
      "com.apple.contacts.postersyncd", "com.apple.contacts.donation-agent",
      "com.apple.AddressBook.AssistantService", "com.apple.AddressBook.SourceSync",
      "com.apple.AddressBook.abd", "com.apple.peopled", "com.apple.notes.exchangenotesd",
      "com.apple.itunescloudd", "com.apple.musicd", "com.apple.amp.mediasharingd",
      "com.apple.mediastream.mstreamd", "com.apple.shazamd", "com.apple.bookassetd",
      "com.apple.bookdatastored", "com.apple.AMPArtworkAgent", "com.apple.AMPDeviceDiscoveryAgent",
      "com.apple.AMPDevicesAgent", "com.apple.AMPLibraryAgent", "com.apple.AMPSystemPlayerAgent",
      "com.apple.videosubscriptionsd", "com.apple.watchlistd", "com.apple.gamed",
      "com.apple.sociallayerd", "com.apple.studentd",
    ],
  ]
}
