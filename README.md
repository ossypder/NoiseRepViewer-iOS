# Noise REP Viewer for iPhone

A small iOS 17+ SwiftUI app that connects directly to a Noise REP band over Bluetooth Low Energy and displays its historical heart rate, daily activity, HRV, stress, SpO₂, and RRI data. It follows the observed read-only sync in [OpenNoiseRep](https://github.com/mohammedr3za/OpenNoiseRep). No account or cloud service is used.

## Run

For AltStore, open the repository's **Actions → Build AltStore IPA** run, download the `NoiseRepViewer-AltStore` artifact, unzip it, and open the contained `.ipa` in AltStore on your iPhone. AltStore signs the unsigned IPA with your Apple ID. You can also run `./build-ipa.sh` on a Mac with Xcode installed.

To build from Xcode, open `NoiseRepViewer.xcodeproj` in Xcode 15 or later, select your development team in **Signing & Capabilities**, and run on a physical iPhone. The simulator cannot connect to the band.

Wake the band or place it on its charger, disconnect NoiseFit or turn Bluetooth off on the phone that normally uses it, and tap **Sync band**.

The app does not set the band's clock. A newly unpaired band may show dates around 2002. Metrics other than heart rate have inferred labels. RRI-based “possible rest” is an estimate; sleep stages are not decoded because no REP sleep file has been captured in the reference project.

This project has been checked for Swift syntax and Xcode project structure, but has not been built with the iOS SDK or tested against a band in this environment.
