# rdp-renderer

An open renderer for the Race Drivin' Panorama world, driven by the cabinet's
own side-pod serial link. Mac first; iPad and visionOS shells to follow on the
same package. Ships no ROM data: the world comes from a bundle you export from
your own dumps.

    RDPKit/     the link framer and decoder, link state with prediction,
                world bundle loader, camera math (the pod's yaw/pitch
                transform) and the original projection
    rdpview/    a Mac wireframe viewer, the skeleton of the faithful renderer

## Build

    swift build
    .build/debug/rdpview world.json --replay capture.bin
    .build/debug/rdpview world.json --udp 5000 --yaw 53

## World bundle

    cd ~/Developer/rdp-fullscreen
    python3 export_bundle.py racedrivpan.zip racedriv.zip -o bundle

`bundle/world.json` (format rdp-world-2): every track's placements, every
object model that decodes (vertices, faces as `[colour, v0, v1, ...]`,
catalogue radius / LOD / cull), names, and the palette banks.

## Feeding it

* **Capture replay**: `--replay file.bin`, with `file.bin.times` beside it
  for recorded pacing (rdp-sidepod/capture, or a MAME log).
* **MAME as the cabinet**: the patched MAME mirrors the Panorama's link onto
  its centre board's serial slot.

        mamehd racedrivpan -mainpcb:rs232 pty ...        # prints the pty
        python3 rdp-sidepod/podlink.py serial /dev/ttysNNN --udp 192.168.1.20:5000
        rdpview world.json --udp 5000

* **The cabinet**: same podlink.py command on a USB-serial adapter (RX and
  ground only; J2 pin 10 carries +12 V), or an ESP32 in the cabinet sending
  the same datagrams over Wi-Fi.

One datagram per link packet, sync byte and checksum included; the decoder
in `RDPKit/Link.swift` documents the layout, and `rdp-sidepod/rdplink.py` is
the Python reference.

## Status (15 Sep 2026)

Phase 0 done (link decoded, pod camera math measured). Phase 1 started: the
Mac viewer draws the world as wireframe from the predicted camera, the cars
the link carries at their positions, and switches track on the roster packet.
Not yet: filled faces in painter's order, the horizon bands, the palette bank
at draw time, the MAME frame diff.
