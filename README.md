# HeaterBar

A macOS menu bar app for Philips Wi-Fi heaters (tested with CX3120 and CX5120).
It talks to them directly on the local network, no Philips account or cloud.

```sh
./build.sh --run
```

- Heaters are found automatically on the Mac's local network and remembered.
- Local protocol: CoAP on UDP 5683, encrypted as in the open-source `aioairctrl`.
  Status keys: `D03102` power, `D0310E` target °C, `D03224` room °C × 10.
- Some models (CX5120) publish their status only after a command, so the app
  sends an empty one to ask. Their first reading can take 10–15 seconds.
- Each heater is always reached from the same local port and subscription token,
  so restarts replace the old subscription instead of piling up new ones.

## Logs for analysis

`~/Library/Application Support/HeaterBar/logs/YYYY-MM-DD.csv`, kept 30 days: one
line each time a heater's state changes (room-only changes are not logged).

| Column | Code | Values |
|---|---|---|
| power | D03102 | 1 on, 0 off |
| selected_mode | D0310C | 0 Auto+ or Auto (told apart by D03180, set in Air+: 1 Auto+, 0 Auto; the card shows whichever is set), 65 High, 67 Medium, 66 Low, −127 Fan (−16 when off) |
| running_mode | D0313F | what actually runs: 65/66/67 heating, −16 Auto+ idle, 0 fan |
| level | D0310D | 1–3 heating power, 4 fan, 0 idle (always 1 on the CX5120: its running mode tells High from Low) |
| function | D0310A | 3 heater, 1 fan only |
| target | D0310E | °C |
| room | D03224 | °C |
| oscillation | D0320F | 0 off; on is 45 on the CX3120, 17920 on the CX5120 (which is switched on with 17222) |
| timer_step | D03110 | 0 off, 1 = 30 min, n = n − 1 hours. The card counts it down: the CX3120 reports the minutes left (D03211), the CX5120 only the setting, so HeaterBar counts from when it saw it set. Switching on clears a timer, so it can only be set while on |
| estimated_watts | | from the level at Philips' rated power. CX3120: Low 800, Medium 1,200, High 2,000 W, fan 2 W (until 2026-10-28 10:4x: measured 900 / 1,100 / 1,900). CX5120: Low 1,200, High 2,000 W, fan 8 W (until 2026-10-28 19:1x it used the CX3120 figures). +3 W oscillating |
| outdoor | | °C in Manage, from Open-Meteo (added 2026-10-28 10:1x) |
| away | | 1 while nobody is at the Mac (see Eco when away) |
| desk | | °C from the desk thermometer, on the Office lines only (added 2026-10-30 20:4x; files from that day on were given the empty columns) |
| desk_humidity | | % from the desk thermometer |
| event | | on lines of their own: each command HeaterBar sent, why, and the heater's answer, e.g. `command D03102=1 (eco: you are back): accepted`; a command re-sent because the heater accepted it but reported otherwise 12 s later ends in `, check`, and `check: no report since …; not sent again` when a heater that only reports changes (CX5120) stayed silent; also `unreachable: no answer to ping`, `reachable again`, and `fault code N` / `fault cleared` (D03240, 0 when all is well; Philips does not document the codes) |

## Eco when away

The leaf button on the Office card (the room this Mac is in) chooses what that heater does while nobody is at the
Mac: nothing, lower the target by 2° or 4°, or switch off. Away means the screen
locked, or no keyboard or mouse input, for 10 minutes, or the Mac going to sleep
(acted on at once). Back means unlocked and used again: the target is restored,
or the heater switched back on, unless it was changed meanwhile. Only heaters
that are on are touched; each change is a command, so it beeps.

The same menu can also switch the heater off after a long absence (1, 2 or 4
hours). It uses the heater's own timer, set in the same command as the lower
target (one beep), so it works even while the Mac sleeps. On return the timer
is cancelled, or the heater switched back on with its target restored. A timer
you set yourself is left alone. The Office (which counts its timer down) also
offers 30 minutes.

Heaters elsewhere (the Bathroom) get only auto-off in that menu: whenever the
heater is switched on, here, in Air+ or on the heater, without a timer, its
timer is set (1, 2 or 4 hours) as soon as it reports being on: not in the
"on" command itself, which the heater drops while switching on, so two beeps
wherever it was switched on. At launch, if it is on without a timer, setting that timer is also
what makes it report, one beep instead of the two of the timer on/off check.

## Desk thermometer

On the Office card the room temperature is the desk's (humidity and battery
on hover), with the heater's own sensor, next to the heater, small below it.
The desk humidity is shown beside it, in grey, or blue when over 60 % (with
the dew point: condensation on the window, mould) and orange under 35 %. It comes from a
Xiaomi Monitor 3 Mini (MJWSD06MMC) running pvvx's
[ATC_MiThermometer](https://github.com/pvvx/ATC_MiThermometer) firmware
(`MJ6_v…`), which broadcasts them in the open BTHome format: no pairing, no
key, no Xiaomi account once flashed. HeaterBar listens to those Bluetooth
broadcasts (macOS asks once for Bluetooth access) and remembers the first
thermometer it hears. The graph draws it as a blue line beside the heater's, and a reading older
than 5 minutes is not shown.

Flashing the factory firmware (2.1.1.0009) over Bluetooth needed its Mi Token
and Bind Key once: add it in Mi Home, get both with
[Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor),
then log in and flash in pvvx's
[TelinkMiFlasher](https://pvvx.github.io/ATC_MiThermometer/TelinkMiFlasher.html) in Chrome.

`history.json` in the same folder holds one reading per minute, kept a week (room, target, Eco,
heating, energy) for the graph, which shows one day at a time. `energy.json` keeps each heater's energy per day for good,
for the total (click the energy line on a card to switch between today and the total) and for the day shown on the back. `logs/2026-10-28-office-raw-status.log` in this
project is the raw capture from the day the codes were mapped.
