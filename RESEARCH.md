# Desktop JioJoin source audit — 12 August 2026

## Bottom line

A desktop implementation is feasible, and Windows source already proves it. I did not find an existing ready-to-run macOS JioJoin client. The useful prior work is fragmented: a GPL Windows client and patched SIP stack, an open provisioning script with no visible license, and a more complete Linux bridge whose repository has no visible license. The cleanest macOS path is a new UI and engine on official GPL PJSIP 2.17, carrying only the small reviewed interoperability changes corroborated by those projects.

## Projects found

- [JFC MicroSIP](https://github.com/JFC-Group/JFC-microsip): GPL-2.0 Windows client modified for JioFiber/AirFiber. This is the strongest proof that a non-phone desktop client works, but its UI is Windows/MFC-specific.
- [JFC pjproject](https://github.com/JFC-Group/JFC-pjproject): GPL-2.0 PJSIP fork with the nonstandard Jio `+sip.instance` handling. It is useful licensed interoperability evidence; the shipped runtime now uses official PJSIP 2.17 with a minimal local patch.
- [JFC SIP Configuration Tool](https://github.com/JFC-Group/JFC-SIP-Configuration-Tool): Python provisioning helper. Public source exists, but no license was visible in the repository audit, so its code was not copied.
- [JioFiber bridge](https://github.com/sivatheja10/jiofiber-bridge): Linux headless B2BUA that documents outbound and inbound service, AMR details, provisioning, password refresh, and Asterisk integration. It is useful evidence, but it is not a Mac app and no license was visible, so its source was not reused.
- [JFC SIP protocol discussion](https://github.com/JFC-Group/JF-Customisation/discussions/70): public packet-level documentation for OTP provisioning, XML fields, REGISTER/INVITE shapes, headers, and AMR formats.
- [India Broadband Forum Windows announcement](https://broadband.forum/threads/jiofiber-sip-client-for-windows.232351/): independent community announcement and links to the Windows source repositories.

## Hacker News and Reddit check

Searches of Hacker News did not surface a JioJoin/JioFiber desktop implementation or relevant source release. Reddit results were user troubleshooting and confirmation that JioJoin works only while connected to the relevant JioFiber/AirFiber network; they did not provide a Mac client or source. The actionable engineering work is concentrated on GitHub and the India Broadband Forum.

## iPad versus Mac

The current Indian App Store listing describes JioJoin as **Only for iPhone**. An iPhone app can often be installed or displayed on an iPad through compatibility mode, but that does not imply a macOS build. Apple-silicon Macs can technically execute many iOS binaries, yet developers may opt out of Mac distribution, and JioJoin also relies on mobile UI/lifecycle, device identity, push notification, networking, and native IMS/media components. An iPad is useful as a second black-box reference for traffic and UI behavior; the Android APK remains better for reverse engineering because Java/smali, resources, and exported native symbols are directly inspectable.

## Architectural conclusion

The Mac does not need a permanent phone bridge. While it must remain on the subscriber's JioFiber LAN and use the router's JUICE SIP proxy, it can itself be the authorized endpoint:

`macOS UI → local OTP/config service (TLS 8443) → local JUICE proxy (SIP/TLS 5068) → Jio IMS`

The remaining uncertainty is live compatibility, not basic build feasibility. Only an approval-gated registration and consenting call test can close that boundary.
