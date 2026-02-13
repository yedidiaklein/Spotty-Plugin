The Spotty Spotify implementation for Lyrion Music Server
=====

Spotty is a somewhat spotty implementation of Spotify for the [Squeezebox](https://lms-community.github.io/players-and-controllers/) and [other compatible](https://www.picoreplayer.org) [music players](https://www.max2play.com) running [Squeezelite](https://github.com/ralph-irving/squeezelite) or [Squeezeplay](https://github.com/ralph-irving/squeezeplay) connecting to a [Lyrion Music Server](https://lms-community.github.io/getting-started/).

You can use any Squeezebox Controller, compatible mobile app or the Lyrion Music Server web interface to play music from Spotify.

The Spotty plugin is known to run fine on recent Windows, macOS, and Linux on x86_64, and many ARM platforms (including Raspberry Pi, many NAS devices, rock64). Some platforms which are not supported out of the box can probably be supported by compiling the [spotty helper application](https://github.com/michaelherger/librespot) yourself - or some [friendly community member](http://www.neversimple.eu/spotty-for-freebsd.html). It's based on the great [librespot project](https://github.com/librespot-org/librespot).

Configuration
---

Most aspects of the Spotty configuration can be configured in LMS directly, in Settings/Advanced/Spotty.

IMPORTANT: on some systems you might need to tweak a firewall, or configure your container to make things work. Please make sure you allow Spotty, and in particular its helper application which you can find in its `Bin` folder, to reach the internet on ports `80`, `443`, and `4070`!

Spotify Connect Support
---

Spotty now supports Spotify Connect, allowing your Squeezebox players to appear as available devices in the Spotify mobile app. This means you can control playback directly from your phone, tablet, or computer's Spotify app.

**To enable Spotify Connect:**

1. Go to Settings → Advanced → Spotty
2. Enable the "Enable Spotify Connect" option
3. Go to Settings → Player → Spotty (for each player you want to use)
4. Enable "Enable Spotify Connect for this player"
5. Optionally, customize the "Spotify Connect device name" that appears in your Spotify app

**Important notes:**

- Spotify Connect uses the modern librespot library (version 0.7.1+) which implements the official Spotify Connect protocol
- For Spotify Connect to work, your firewall must allow:
  - mDNS/Zeroconf traffic (UDP port 5353) for device discovery
  - Spotify streaming ports (TCP ports 80, 443, 4070)
  - The spotty helper needs network access on these ports
- The device will appear in your Spotify app's "Available devices" list (usually under the connect icon)
- You can control playback, volume, and track selection directly from the Spotify app
- Both local LMS playback and Spotify Connect playback can be used simultaneously on different players
- Each player configured for Connect will run its own spotty process for independent control

**Troubleshooting:**

- If your device doesn't appear in the Spotify app, check your firewall settings and ensure mDNS/port 5353 is not blocked
- Make sure you're on the same network as your Squeezebox players
- Check the Lyrion Music Server logs for any Spotify Connect related errors
- Try restarting the Lyrion Music Server after enabling Connect mode

Disclaimer
---

Using the spotty helper and the librespot code to connect to Spotify's API is probably forbidden by them. Use at your own risk.

