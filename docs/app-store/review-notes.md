# App Store Connect — Notes for App Review

Paste the text between the `-----` markers into **App Store Connect → App Review
Information → Notes**. Plain text, no markdown.

-----

Nearby is a walkie-talkie style voice room between iPhones. There is no
account and no sign-in. Phones that are physically near each other find each
other over the local network (Bonjour), Wi-Fi Aware or Bluetooth and talk
directly, with no server. Friends who exchanged friend codes can also call
over the internet; those calls connect through our rendezvous server and,
when no direct path exists, an encrypted relay that needs the subscription.

Review requires TWO iPhones running this build, on the same Wi-Fi or with
Bluetooth on.

1. Open the app on both phones. Grant Microphone and Local Network (and
   Bluetooth if prompted). The home screen says "Looking for people nearby"
   until the other phone is found, then "1 person nearby".
2. On phone A tap "Start a room". On phone B the room appears under "Nearby
   rooms" — tap it to ask to join.
3. Phone A shows "Wants to join" — tap Accept. Both phones are now in the room
   and can hear each other. The room name can be changed from the line under
   "Start a room".
4. While in a room, lock either phone: a Live Activity with mute and leave
   buttons appears on the lock screen and in the Dynamic Island.
5. The red hang-up button leaves the room. If the host leaves, the room
   continues for the remaining members.

Background audio: the "audio" background mode keeps the call running while
the app is in the background, exactly like a phone call. Bluetooth background
modes keep the peer link alive on phones with no shared Wi-Fi.

Data: voice and display names are sent only to the phones in the room,
end-to-end encrypted (CryptoKit). Nearby calls use no server. Internet calls
pass encrypted packets through our server; it cannot read them. The server
stores only two records per anonymous node ID: relayed minutes for the
current month and an App Attest key. This matches the App Privacy answers
(Identifiers, Usage Data) and the privacy policy.

-----
