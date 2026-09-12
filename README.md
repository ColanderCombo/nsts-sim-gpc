
nsts-sim-gpc - Space Shuttle AP-101 Simulator
---------------------------------------------

This repository implements an instruction level simulator for the
IBM 4Pi AP-101 computer, specifically the B & S models used as the
Space Shuttle Flight Computers.

A single `gpc` command provides several entry points: a batch mode
that executes the provided code and emits a trace, a terminal-based
interactive debugger, the same debugger headless on a socket, an
Electron GUI debugger, and a static disassembler/dumper. All of them
read the same `.fcm` ('flight computer memory') files.

The repository also contains a simulator for MEDS, the Multifunction
Electronic Display System ("glass cockpit") that replaced the original
CRT/DEU displays.  A `meds` command launches MDU display units and
IDPs (Interface/Display Processors) in their own windows; they talk to
each other — and to running GPCs — over the same simulated UDP-multicast
flight-critical busses.  See the MEDS section below.

Every bus is a UDP multicast port at a fixed offset from a base port.
Every command that opens a bus takes `--base-port <n>` and
`--bus-iface <addr>`, defaulting to `NSTS_BASE_PORT` (6900) and
`NSTS_BUS_IFACE` (loopback), and `sim --base-port` hands one base to
every LRU it starts.  The table is `com/bus.civet`.

`NSTS_BUS_SHM`, or `--bus-shm`, moves named busses off UDP and into a
shared-memory ring the session's processes read directly: `ic` for the
inter-computer busses and the GPCs' discrete channels, `headless` for
every bus but the five the Python members hold, `all`, `off` (the
default), or a list of bus names.  Every process of a session takes the
same setting; `gpc shm` lists the processes on the ring, and
`gpc shm --unlink` drops it.  The MEDS display windows and the GUI
debugger's GPC run under Electron, whose V8 refuses the mapping, so a
session holding one of those takes `ic` or `off`.  A GPC reads and writes
the ring from inside its instruction loop, so a partner's words arrive
without a turn of either event loop; measured between two processes,
68-byte messages a millisecond apart, one way:

| transport | p50 | p90 | p99 | max |
| --------- | ----- | ----- | ------ | ------ |
| UDP multicast | 67 us | 90 us | 223 us | 925 us |
| shared memory | 10 us | 15 us | 30 us  | 416 us |

The ring needs `native/shmring.node`, built by `native/build.sh`; without
it every bus is UDP.  `realtime` in the debugger reports what the rings
have carried.

`NSTS_SIM_BARRIER`, or `--barrier <us>`, holds the paced machines of a
session inside one simulated time: each publishes the time it has
reached in the same segment and none advances past the least of the
others by more than that many microseconds, so two computers reach a bus
exchange within the figure of each other.  `off` is the default.  A
common set of two GPCs on the inter-computer busses runs at 50; `gpc
shm` lists the machines on the barrier and `realtime` reports what it
cost.

Those commands also take `--sched <policy>` (or `NSTS_SCHED`), the
scheduling policy their event loop runs under on macOS: `off`, `qos`,
`fixed` (the default) or `rt`.  The flight software times its busses and
its common set syncs in milliseconds, so what counts is the tail of a
thread's wakeup.  Measured on a Mac15,9 running a two-GPC session, in
four interleaved rounds of 5000 one-millisecond timers per policy, how
late the timer fired:

| policy | priority | p50 | p99 | p99.9 | max | over 1 ms |
| ------ | -------- | ------ | ------ | ------ | ------ | --------- |
| off    | 31       | 144 us | 172 us | 330 us | 5.3 ms | 6 of 20000 |
| qos    | 31       | 144 us | 170 us | 222 us | 2.3 ms | 1 of 20000 |
| fixed  | 63       | 144 us | 160 us | 204 us | 0.61 ms | none |
| rt     | 97       | 143 us | 156 us | 194 us | 0.60 ms | none |

`fixed` and `rt` need `native/machrt.node`, built by `native/build.sh`
(`BUILD.sh` builds them); without it the option has no effect.  What the
policies do is in `native/rtpolicy.coffee`, and `native/rtjitter.coffee` measures
a round trip between two processes under each.

The [nsts-sdl-dps](https://github.com/ColanderCombo/nsts-sdl-dps) repository provides wrappers to create a AP-101 toolchain
and a cmake based build system that is the preferred way to use the gpc-sim.

[nsts-sdl-dps](https://github.com/ColanderCombo/nsts-sdl-dps)  provides:
    - gpc wrappers
    - asm101s, A macro assembler from the virtualagc project
    - lnk101s, a relocating linker
    - halsc - wrappers around the HAL/S-FC compiler, which generates AP-101
      object modules.

The simulator loads and runs '.fcm' ('flight computer memory') files, which are
simply an absolute image of the AP-101's memory, starting at 0x00000 and extending
up to the 1MB limit.  lnk101s produces these files, and will also output a .sym.json
file containing symbols and optionally used by the debugger.

Setup
-----

The simulator is a nodejs/electron app built with cmake, and requires node,
npm and cmake installed before use.  `BUILD.sh` configures the build tree
and builds everything:

```
cd nsts-sim-gpc
./BUILD.sh
```

The first run installs electron and all the other npm packages, so it might
take a while.  Everything it produces lands in `build/`: the node bundles in
`build/dist`, the native addons in `build/native`, and the commands in
`build/bin` — `gpc`, `sim`, `meds`, `mmu`, `mdm` and the rest.  Put
`build/bin` on your PATH, or run them by path.

```
./BUILD.sh gpc-bundle     # one bundle
./BUILD.sh check          # build, then run the tests
cmake --build build --target electron   # the Electron main and renderer
```

Each command in `build/bin` rebuilds what it needs before running, so an
edit to a `.coffee` file takes effect on the next invocation;
`NSTS_NO_BUILD=1` skips that.

If you use the simulator via the sdl build system, it will take care of all of this for you.

Prebuilt Package
----------------
If you find it inconvenient to work from the source tree, you can get a prebuilt linux AppImage or macOS bundle from the releases page:

https://github.com/ColanderCombo/nsts-sim-gpc/releases/tag/latest

These packages bundle the node and electron runtimes and should make things easier if you run into library or path problems.

Usage
-----

`gpc` is a thin wrapper that builds the bundles if needed and then
dispatches to one of the `gpc` subcommands.  All subcommands take an
`.fcm` file as input.

```
Usage: gpc [options] [command]

AP-101 GPC Simulator

Commands:
  run [options] <fcm-file>        Run an AP-101 program in batch mode
  dbg|debug [options] [cmd...]    Drive a session: a prompt, one command, a script
  dbg-serve [options] [fcm-file]  A session on a socket, with no interface
  gui [options] [fcm-file]        Electron GUI debugger
  dump [options] <fcm-file>       FCM dump report — symbol table and disassembly
  disasm [options] <fcm-file>     Disassemble an FCM memory image
```

  ## gpc run \<fcm\>
```
Usage: gpc run [options] <fcm-file>

Run an AP-101 program in batch mode

Arguments:
  fcm-file                        FCM memory image to load

Options:
  --start <addr>                  start address in hex
  --power-on                      enter from the power-on PSW in the PSA
  --sys-reset                     enter through the system reset PSW in the PSA
  --ipl                           run hardware IPL on startup, as though the IPL
                                  discrete was asserted.
  --symbols <file>                load symbol table JSON from linker
  --ebcdic                        use EBCDIC encoding for character I/O
  --trap-svc-error                intercept HAL/S SEND ERROR SVCs (default)
  --no-trap-svc-error             pass SEND ERROR SVCs to SVC handler
  --halucp-format-num-blanks <n>  blanks between WRITE output fields (default: 5)
  --line-width <n>                WRITE line width for wrap (default: 132)
  --infileN <file>                read input for channel N (0..7)
  --outfileN <file>               write output for channel N (0..7)
  --max-steps <n>                 max instructions to execute (default: 100000)
  --real-time                     pace execution at AP-101 speed
  --rt-factor <x>                 real-time speed multiplier (2 = 2x real speed)
  --rt-idle-timeout <s>           stop after this long in the wait state with no wakeup
  --break <addr>                  stop at halfword address (hex)
  --break-on-interrupt            stop when an interrupt is accepted
  --hold-interrupt                stop just before an interrupt swaps PSWs
  --watch <spec>                  memory watchpoint: addr[:count] in hex
  --watch-log                     log every watchpoint change instead of breaking
  --output <file>                 write trace/verbose output to file instead of stdout
  --dump-interval <n>             register dump every N steps (default: 100)
  --trace / --no-trace            enable/disable instruction trace (default off)
  --verbose / --no-verbose        print informational messages (default off)
  --interactive                   interactive terminal I/O
  -h, --help                      display help for command
```

### IPL

`--ipl` implements the hardware Initial Program Load as described in 
IBM-74-A31-016/p.68 sect.2.7.  In response to the IPL discrete being
asserted while the CPU is in the `HALT` state, IOP microcode sequences
clearing memory and loading an initial bootloader `FCMBOOT` from a
fixed location on the MMU.  `FCMBOOT` then manages reading the complete
`GPCIPL` system loader from MMU.

```
node build/dist/mmu.js run --unit 1 --volume /path/to/mmu.mmv &
node build/dist/gpcmd.js unit --idp 1 --ipl-request &
gpc run --ipl --real-time --max-steps 0 --gpc 4
# once the menu is up on DK1:
node build/dist/gpcmd.js key --idp 1 ITEM 1 EXEC
node build/dist/gpc.js discretes mode run --gpc 4
```

`--ipl` stands in for the panel, which can drive the same thing from
outside: the mode toggle to HALT holds the CPU in system reset and halts
every IOP processor, a press of the IPL button then loads, and moving the
toggle off HALT starts the machine from the system reset PSW.

```
node build/dist/gpc.js discretes mode halt --gpc 4   # or `panel`, then `halt`
node build/dist/gpc.js discretes ipl --gpc 4         # the pushbutton
node build/dist/gpc.js discretes mode run --gpc 4
```

Each line runs to one computer, at bus offset 80 + GPC ID, and every
`discretes` subcommand takes `--gpc <n>` to say which.  `set`, `mode`,
`ipl` and `watch` also take a comma list or `all`.  GPC 0, the default,
is a standalone computer.

GPCs 1 to 5 are wired to each other: a GPC's SYNC 1/2/3 and BFS RUN
outputs (DO-20, 24, 28 and 22) arrive as inputs at the other four,
numbered N+1 to N+4 around the ring (DI-20 to 31, DI-8 to 11).  Each GPC
listens on the other four discrete channels and drives its own inputs
from what it hears, each change landing on its own clock with the spacing
the sender stamped it with (`gpc/gpclinks.coffee`); a GPC that stops
answering reads as powered off.  `discretes links --gpc 2` prints the
table.

On real hardware the IPL is implemented in microcode, but since we don't
currently implement microcode we have a stand-in assembly program at
`gpc/asm/fakeipl.asm` (pre-generated object code at 
`gpc/asm/fakeipl.json`).  This program is placed at 0x3FF80.  This is
a deviation from real hardware, but the idea is to do something *close*
to what the hardware actually does, which includes running MSC/BCE programs
to read from MMU. 

  ## gpc dbg

Every way of running a GPC is the same debug session: `gpc run` puts a
batch console on one, `gpc gui` a window, `gpc dbg-serve` a socket and
nothing else, and `gpc dbg` a prompt.  The prompt does not care whose
session it is.

```
gpc dbg prog.fcm                # open a session here and prompt
gpc dbg prog.fcm step 10        # ... and run one command instead
gpc dbg --port 4444             # attach to one `gpc dbg-serve` left
gpc dbg                         # ... to the most recently started one
gpc dbg --name gpc1 regs        # ... to a named one, under `sim`
printf 'break MYPROC\ncontinue\nregs\n' | gpc dbg
```

A leading `*.fcm` argument (or `--image`) opens a session in this process
and serves it on an ephemeral port; everything after it is the command.
With no image the endpoint comes from `--port`/`--socket`/`--name`, or from
the session file the newest server wrote.  `dbg-client` and `dbgc` are
aliases, so a script that drove a headless session still does.

A session opened by the prompt goes when the prompt does; one started by
`dbg-serve` or `gui` outlives every client, which is what makes a debugging
session a sequence of separate shell commands against a machine that keeps
its place between them.

`help` lists what the session can do -- the command table is the session's,
so the prompt, a script, the GUI and an agent all drive the same one.

Interrupt and interval-timer commands:

```
  int                     interval timers, the interrupt repertoire, and what is
                          pending, masked or blocked
  int raise <key> [code]  force an interrupt (clk1 clk2 ext0..ext4 svc
                          machineCheck programCheck instrMonitor)
  int clear <key>         clear a pending latch
  int mask <bit> [on|off] change a PSW mask bit (32-39 system, 45 machine check)
  int log [count]         interrupts accepted, with simulated time and NIA
  int break [on|off]      break when an interrupt is accepted
  int hold [on|off]       stop in front of the PSW swap, not after it
  timer [n] [value]       show or load an interval timer (as the ICR would)
```

`int break` stops at the first instruction of the handler; `int hold`
stops one step earlier, at the instant the interrupt is accepted and
before the PSW swap, so the registers, the PSW and the NIA are still the
interrupted program's and the old-PSW slot still holds what was there
before.  The next `step` performs the swap alone, landing on the
handler's first instruction without executing it; `run` performs it and
carries on. 

  ## gpc dbg-serve \<fcm\>

A session with no interface of its own, on a socket.  It holds the machine
in a process that outlives any one command, so `gpc dbg`, a window, or
`sim` can come and go against a machine that keeps its place.

```
gpc dbg-serve prog.fcm &              # hold a session, port 4444
gpc dbg break MYPROC           # ... set a breakpoint by symbol
gpc dbg continue               # ... run until it hits
gpc dbg regs                   # ... look around
gpc dbg mem MYVAR 8
gpc dbg --json regs R6         # ... structured, for a program
gpc dbg shutdown
```

With no command arguments and a terminal on stdin it is a prompt on the
session, with completion from the commands the server reports and a history:

```
gpc dbg --name gpc1
gpc1> break MYPROC
gpc1> continue
gpc1> regs
```

The prompt stays live while a command is outstanding, so `pause` reaches a
`continue` that has not come back yet.  `quit` or Ctrl-D leaves; the session
carries on without it.

Reading from a pipe instead, it runs a command per line, so a whole session
is one invocation:

```
printf 'break MYPROC\ncontinue\nregs\ntracelog 20\n' | gpc dbg
```

`--no-prompt` takes that path at a terminal too.

`help` lists the commands and `help <command>` describes one.  The vocabulary
follows the REPL debugger's: `step`, `next`, `continue`, `until`, `pause`,
`break`/`bclear`/`breakpoints`, `watchmem` (data breakpoints, on change or on
any write), `watch`, `mem`/`writemem`, `regs`/`setreg`, `disasm`, `sym`,
`sections`, `resolve`, `ints` and the `int*` controls, `timers`, `iop`,
`iopdisasm`, `realtime`, `output` and `input`.  Addresses are hex, a symbol,
or either with a `+`/`-` offset (`IOINIT+0x10`).

Beyond it: `trace`/`tracelog`, `busmon`/`buslog`/`bus`,
`discretes`/`discmon`/`disclog`/`discset`, `log`/`logstop`,
`logpoint`/`logpoints`, `find`, the symbol layers
`symload`/`symswitch`/`symlayers`, the SDL database `sdl`/`hal`/`halinfo`/
`val`/`halat`, and `symauto`.

### Watching the machine

`trace on` records the instructions that execute into a ring, and `tracelog`
prints it back disassembled — the last N instructions before a stop, without
the cost of streaming every one of them.

`busmon on` taps every word crossing every BCE's bus, `buslog` prints it back
grouped into transactions, and `bus` lists what this GPC is attached to with
its transmit/receive enables, counts, and the receive each BCE is sitting in:
how many words it still wants, how long it has been waiting and when the next
queued word falls due.  The tap sees more than the MIA's own
64-word ring keeps, and `--bus DK1,MM1` narrows it.

```
gpc dbg busmon on --limit 4000
gpc dbg buslog 20              # ... as transactions
gpc dbg buslog 40 --words      # ... word by word
```

`discretes` shows the discrete input and output registers decoded to named
lines (`halt`, `standby`, `run`, `ipl`, `mm1ready`, `gpcid0`…) and names the
self-sync code the three lines of DO-20/24/28 carry (`IOC (001)`), on this
computer's outputs and on each partner's inputs; `discmon on` records every
change to them with that code, and `disclog` prints those back.  Discrete
inputs arrive from other processes at any time, so the monitor hooks the
receive path and sees them whether or not the machine is running; the outputs
are written by a PCO and are sampled once per instruction.  `discset run`
drives a line directly, standing in for the box that owns it.

Traffic is dense, so a monitor fills its ring and any open log but does not
push events at connected clients unless asked: add `--events` to have it
broadcast as well.

### Recording to a file

`log <file>` records what the session publishes, one line per record, stamped
with **both clocks** — the host's wall clock, for lining a run up against
anything outside this process, and the machine's simulated time, which is the
only one that means anything between two events inside it.

```
gpc dbg log run.ndjson --kinds bus,discrete,stopped
gpc dbg log run.txt --format text     # a padded line per record
gpc dbg log                           # what is being recorded
gpc dbg logstop
```

`--kinds` selects what is recorded; with none, everything the session
publishes. `ndjson` gives `{kind, stamp, body}` per line; `text` gives a
column-aligned line for reading.  `GPC_IOP_BCE=<n>`, a comma list of them or
`all`, adds a `trace` kind carrying one bus control element's state as it
moves: enables, program counter loads, the start and completion of each
receive, each transmission, and every word heard on a bus this computer does
not command, with the age of the datagram that brought it.

Two computers' logs merge on the wall clock:

```
tools/timeline.py <tag> --anchor FCMSFAIL --before 400   # both, one clock
tools/cs_report.py <tag>                                 # what became of a run
```

`timeline.py` prints a window of both computers' records around an event,
`cs_report.py` answers whether the joiner found the set, whether the member
added it, how long it held, which computer failed the sync first, and how the
inter-computer exchanges were timed.

### Breakpoints that do not stop

`logpoint <addr> [message]` records an arrival — location, hit count, the
general registers — and lets the run carry on.  It is the way to see a path
taken thousands of times without stopping at any of it.

`break` takes `--ignore N` to pass the first N arrivals (the hit count still
counts them) and `--once` to remove itself after firing.  `breakpoints` lists
hit counts.

### Symbols for an overlay

A load or an overlay puts different code at addresses another load already
named, so one symbol table per image does not describe the machine.  Symbol
tables are layered over the image's own, each optionally scoped to an address
range, and a lookup takes the topmost enabled layer covering the address.

```
gpc dbg symload OVL_A.sym.json --name A --lo 10000 --hi 1ffff
gpc dbg symload OVL_B.sym.json --name B --lo 10000 --hi 1ffff
gpc dbg symswitch A      # A is in force; B stands down
gpc dbg symlayers        # what is loaded and which are in force
gpc dbg symunload B
```

`symswitch` enables one layer and disables every other layer whose range
overlaps it, which is the state after a load: the addresses belong to what was
loaded last, and the layers describing what used to be there stay on the stack
to switch back to.  `sym` and `sections` report which layer a name came from,
and `resolve` names it for one address.

### The SDL database

The linker's symbol table names csects and their entry points. The SDL
index (`sdlindex <CFG> --mmu <root>`, written as `<CFG>.sdl.json` beside
the image) names what the compiler put inside them: the HAL/S block a code
csect holds, the declared variables of a `#D`/`#P` data csect with their
types, the structure templates they instantiate, and the address of every
executable statement.

It loads with the image, the way the symbol table does; `--sdl <file>`
names another and `sdl` reports the one in force.

```
gpc dbg hal GRT              # blocks and variables by substring
gpc dbg hal --units CZ2      # the compilation units
gpc dbg halinfo CZ2V_GRT_PHASES     # its declaration and address
gpc dbg val ARC_CURRENT_MC          # read it, decoded by its type
gpc dbg halat 300e4                 # block, statement and variable there
```

`val` decodes INTEGER and SCALAR in both precisions, BIT(n) at its packed
shift, CHARACTER(n) in EBCDIC, EVENT, VECTOR and MATRIX by component,
arrays element by element, and a structure through its template, one copy
at a time. `--limit` caps the elements or copies read and `--fields` the
elements of a structure member.

A HAL name resolves as an address anywhere one is taken, so `break`,
`mem`, `watchmem` and the rest take them. A name carried by more than one
compilation unit is qualified `UNIT.NAME` or `CSECT.NAME`.

### FCOS processes

Every schedulable process has a process directory entry in the load, and
every scheduled one a process control table entry chained off the
communication vector table. `tasks` reads all of it out of the machine:
what is scheduled, what each waiting process is waiting for, and what the
load carries that nothing has scheduled.

```
gpc dbg tasks               # what is scheduled
gpc dbg tasks --all         # ... and everything that is not
gpc dbg tasks ASH_RW_CYC_UPDATE     # one process in full
gpc dbg queues              # the run, timer and event queues
```

The queue heads are read by symbol (`TCVTPCT`, `TCVTOLD`, `TCVTTTQE`), so
the image's own symbol table decides where they are; only the layouts of a
PCT, a directory entry and a timer or event queue element are constants.
A directory entry is a `#E` csect, one per process, and the SDL index turns
its stem into the HAL/S name.

A waiting process reports the queue element holding it: the time a timer
element expires at, in the ground's day-of-year form, or the event
variables an event element is waiting on. `queues` walks the three chains
as they are linked, and reports the free pools, which is where a schedule
that fails for want of a control block shows.

### Which memory configuration is in storage

An OPS transition overlays SSW's phases with the memory configuration's,
and the symbols loaded with the image stop describing what is there.
`symauto` reads the answer out of the machine two ways and takes the
winner's symbol table and SDL index on.

Memory is the first: every composed image in the build says which phase's
load blocks own which halfwords, so comparing storage against a phase's
store-protected text gives the fraction of that phase which is resident.
A configuration is in storage when every phase of it is, and the answer is
the most specific one that holds. The flight software's record is the
second: `ARC_CURRENT_MC` is the configuration ARCGPC moded to and
`CZ2V_GRT_PHASES` gives that MC's phases.

```
gpc dbg symauto                     # both answers, no change
gpc dbg symauto --adopt             # ... and take the winner on
gpc dbg symauto on                  # re-check at every stop
gpc dbg symauto --config G3         # take a named one on
```

The configurations are found beside the loaded image. A machine IPLed over
the bus was never given one, so `dbg-serve --config-root <dir>` (or
`symauto --root <dir>`) names the build root holding them.

### Searching memory

```
gpc dbg find 4142 4344                    # a run of halfwords
gpc dbg find --text ERROR --encoding ebcdic
gpc dbg find --text ABC --start 10000 --end 1ffff
```

### Server options

```
  --port <n>              TCP port to listen on (default: 4444)
  --host <addr>           address to bind (default: 127.0.0.1)
  --no-tcp                do not listen on TCP; requires --socket
  --socket <path>         also listen on a unix socket
  --name <name>           session name, for the session file
  --session-file <path>   where to record the endpoint
  --break <addr>          set a breakpoint before starting (repeatable)
  --trace                 start with the instruction trace ring on
  --max-steps <n>         step budget for one continue
```

The server records its endpoint in `<tmpdir>/gpc-dbg/<name>.json`, and a
client given no `--port`/`--socket` connects to whichever session started
last.  `--name` picks among several.

### The protocol

One JSON object per line, both ways.  A request:

```json
{"id": 1, "cmd": "step", "args": {"count": 10}, "text": true}
```

and its reply, `text` carrying the rendered form when the request asked for
it:

```json
{"id": 1, "ok": true, "result": {"reason": "step", "steps": 10, ...}}
{"id": 1, "ok": false, "error": {"code": "badArgs", "message": "..."}}
```

Execution commands reply when the machine stops, so replies can arrive out of
order; each carries the id of its request.  Queries are answered while a run
is in progress, and `pause` stops one.

Events are pushed to every connection, unsolicited:

```json
{"event": "stopped", "seq": 12, "body": {"reason": "breakpoint", ...}}
```

`stopped`, `continued`, `running` (progress at each refresh interval),
`output` (program output as it is written), and `input` (the program is
waiting for a read).  Stop reasons are DAP's vocabulary where one applies —
`entry`, `step`, `breakpoint`, `data breakpoint`, `pause`, `exception` — with
`halt`, `interrupt`, `interrupt held`, `input` and `step budget` added for the
states an AP-101 has and a hosted process does not.

A line that is not JSON is taken as a command line — `step 10` — and answered
with `text` filled in.  It carries no id, so its reply has `id: null`; a
client issuing more than one command at a time sends JSON.  `mode text`
switches a connection to plain-text replies, each closed by a blank line,
which is what makes the server usable from `nc`:

```
$ nc 127.0.0.1 4444
mode text
break MYPROC
continue
```

The GUI is another client of this protocol: every pane it draws is filled
from one of these commands.  See **gpc gui** below.

  ## gpc gui \[fcm\]

Launches the Electron-based debugger.  The fcm argument is optional;
the GUI can also load a file from the File menu.

```
Usage: gpc gui [options] [fcm-file]

Options:
  --start <addr>                  start address in hex
  --symbols <file>                load symbol table JSON from linker
  --ebcdic                        use EBCDIC encoding for character I/O
  --real-time                     start with real-time pacing on
  --rt-factor <x>                 real-time speed multiplier (2 = 2x real speed)
  --rt-idle-timeout <s>           stop after this many wall seconds in wait
                                  state with no wakeup
  --max-steps <n>                 step budget for one Run (default: 10000000)
  --attach                        do not start a session; join one already
                                  running
  --port <n>                      TCP port: of the session to attach to, or to
                                  listen on (default: an ephemeral one)
  --name <name>                   session name, used for the session file
  --no-session-file               do not record the endpoint anywhere
  --no-sandbox                    pass --no-sandbox to Electron (required on
                                  some Linux systems)
```

The window drives a debug session, so `gpc dbg` can work on the same
machine from a terminal — breakpoints, memory, bus and discrete monitoring —
while the panes watch.  `--attach` joins a `dbg-serve` already running instead
of starting a session, and the session outlives the window.

Simulated CPU time is tracked per instruction so a debugging session sees 
the same interrupt sequence a straight run does.  The toolbar's **Real-time** 
checkbox additionally ties that simulated time to the wall clock: execution 
is paced to AP-101 speed (times the factor beside it). In real-time mode,
entering the wait state advances simulated time until an interval timer 
or other interrupt wakes the CPU (The IOP will continue to run).
`Step` in the wait state does the same in one jump, landing on the next
interrupt.  The toolbar shows simulated time since power-on and how fast 
it is running against the wall clock.

Execution runs in 200 ms slices of wall time between display refreshes,
so the panes update at a steady rate whatever speed the host manages.

Interrupts
==========

The **Interrupts** pane collects interrupt history and controls, presenting
the pending latch, the PSW mask bit, and the PSA vector. It shows both 
interval timers (editable), every interrupt its class, mask bit and new-PSW 
address, and a log of what has been accepted and where it went.  Buttons raise
or clear a pending latch the way the AGE could, a click on the mask cell
flips that bit in the PSW, `break` stops the run at the first instruction
of any handler, `hold` stops it one step earlier — in front of the PSW
swap, with the interrupted program still in the registers and the NIA,
which Step or Run then completes — and `system reset` performs the POO
2.5.3.2 reset.  What is being held is spelled out under the interrupt
list and on the toolbar (`INT HELD`).

IOP
===

The **IOP** pane presents the current state of the Input/Output Processor.
The IOP is a timesliced parallel processor.  One ALU and datapath is shared
by one "Master Sequence Controller" (MSC) and 24 "Bus Control Elements" (BCEs).
Each tick the IOP executes instructions for one processor, stepping through
the MSC and BCEs in order (each BCE get's one slot/round, the MSC gets several)

In the panel, a foldable **REGISTERS** section lists every register that
belongs to the IOP rather than to one processor, raw: the four
per-processor status words (STAT1/STAT4/STAT5 and the indicator bits),
the MIA enables, the RM status word the CPU reads and the latch word
behind it, all five interrupt registers, the discretes, the data word the
last PCI/PCO left, the GO/NO-GO count and the MSC's own two.

Below that each processor is one line — its STAT5/STAT4/STAT1, its MIA 
transmitter and receiver enables, and its local store registers
(PC, the fetched instruction, and then X/ACC/ECR/status for the MSC or
D/ID/MTO/BASE/IUAR/status for a BCE).  

Clicking a processor unfolds three more lines: a short disassembly at its
PC (with the PC's own instruction highlighted, in the MSC or BCE
instruction set as appropriate), then a ring of the words its MIA has put
on its bus and a ring of the words that have come back — command words
starred, each with the simulated time it crossed.  

`active only` hides the processors that are halted, idle and silent.

An existing saved layout won't have the newer panes: right-click a pane
and pick **Add editor → Interrupts** or **→ IOP** (the default layout
carries both as tabs beside Watch and Breakpoints).

![GPC debugger window screenshot](doc/gpcDebuggerWindow.png)

  ## gpc dump \<fcm\>
```
Usage: gpc dump [options] <fcm-file>

FCM dump report — symbol table and disassembly

Options:
  --symbols <file>  symbol JSON file (default: <fcm>.sym.json)
  --no-symbols      allow running without symbol file
  --output <file>   write output to file instead of stdout
  --columns <n>     columns in symbol table grid (default: 7)
```

  ## gpc disasm \<fcm\>
```
Usage: gpc disasm [options] <fcm-file>

Disassemble an FCM memory image

Options:
  --start <addr>    start address in hex
  --end <addr>      end address in hex
  --symbols <file>  load symbol table JSON from linker
```

MEDS — Glass Cockpit Displays
-----------------------------

MEDS is two kinds of LRU.  The MDUs are windows: `meds` builds the
bundles if needed and launches them by name, with the window geometry
and initial display of each in `config/meds.json`.  The IDPs are a
process with no window, `idp`, like the other LRUs.

```
meds --list                 # list the MDU names
meds crt1                   # a center CRT MDU
meds cdr1 plt1              # commander + pilot MDUs
meds --display AE_PFD crt2  # override the initial display
meds --dev crt1             # developer mode (standalone MDU)
idp run                     # IDP 1 to 4, on the DK, FC, keyboard and MDU busses
idp run --units 1 --ipl-request 1   # one IDP, asking the GPC for its load
idp run --fill data/TEST-9011-GPC_MEMORY.dfb   # a display with no GPC
idp units                   # the units and their busses
```

MDU positions match the orbiter cockpit: `crt1`–`crt4` (center),
`cdr1`/`cdr2` (commander), `plt1`/`plt2` (pilot), `mfd1`/`mfd2`,
and `afd1` (aft flight deck).  Each MDU is on the busses of its primary
and secondary IDPs (`meds/medsConf.coffee`), and goes autonomous when the
IDP commanding it stops.  An IDP (`meds/idp/`) is the DEU protocol state
machine on its DK bus, the bus controller of its two ADCs, the receivers
on the four FC busses and the keyboards the IDP/CRT SEL switches route to
it; everything it has for its MDUs goes out on its 1553B bus as the
messages tagged in `meds/medsConf.coffee`.

An IDP's discrete lines run on a channel of their own, `_idpDiscretes<n>`
at bus offset 85 + n, in the same message shape as a GPC's
(`com/discretes.coffee`, `meds/idp/idpDiscretes.coffee`): KYBD SEL A and
B, which the IDP/CRT SEL switches on panel C2 make, and the IDP LOAD
momentary on panel O6.  Taken to LOAD, the IDP asks the GPC assigned to
it for a load in every poll (USA-005350 sect.3.7.1), its DPS display
shows VM LOAD IN PROGRESS, and a GPC running an OPS that supports the
load (SM OPS 2 or 4, PL OPS 9, or OPS 0 after an IPL) performs it; the
last fill of the load clears the request.  The IDP publishes its load
state on the channel's STATUS register.

```
gpcmd idpsel 3 2                   # LEFT IDP/CRT SEL to 3, RIGHT to 2
gpcmd idpsel                       # the positions, read back from the IDPs' lines
gpcmd idpload 1                    # IDP 1's LOAD momentary
gpcmd monitor _idpDiscretes1       # the traffic on IDP 1's channel
```

Each MDU is a 720x720 vector display rendered with Three.js: the
edgekey menu system, the AE PFD with its 3D ADI ball, HSI and scrolling
AMI/AVVI tapes, and various subsystem status displays (HYD/APU, 
OMS/MPS, SPI, ...).  The DPS display implements the original DEU 
FCW protocol generated by shuttle software.

*** Keybindings

The MDU edgekeys sit along the bottom of the screen, and `F1`-`F6` press
them:

<table style="width:50%;table-layout:fixed;border-collapse:collapse;text-align:center;">
<colgroup><col style="width:7.143%"><col style="width:7.143%"><col style="width:7.143%"><col style="width:7.143%"><col style="width:7.143%"><col style="width:7.143%"><col style="width:7.143%"><col style="width:7.143%"><col style="width:7.143%"><col style="width:7.143%"><col style="width:7.143%"><col style="width:7.143%"><col style="width:7.143%"><col style="width:7.143%"></colgroup>
<tr>
  <td colspan="14" style="height:7em;border:1px solid #888;"></td>
</tr>
<tr>
  <td colspan="1"></td>
  <td colspan="2" style="border-left:2px solid #2a6fdb;border-right:2px solid #2a6fdb;border-top:2px solid #2a6fdb;border-bottom:none;padding:0.4em 0;">(F1)</td>
  <td colspan="2" style="border-left:2px solid #2a6fdb;border-right:2px solid #2a6fdb;border-top:2px solid #2a6fdb;border-bottom:none;padding:0.4em 0;">(F2)</td>
  <td colspan="2" style="border-left:2px solid #2a6fdb;border-right:2px solid #2a6fdb;border-top:2px solid #2a6fdb;border-bottom:none;padding:0.4em 0;">(F3)</td>
  <td colspan="2" style="border-left:2px solid #2a6fdb;border-right:2px solid #2a6fdb;border-top:2px solid #2a6fdb;border-bottom:none;padding:0.4em 0;">(F4)</td>
  <td colspan="2" style="border-left:2px solid #2a6fdb;border-right:2px solid #2a6fdb;border-top:2px solid #2a6fdb;border-bottom:none;padding:0.4em 0;">(F5)</td>
  <td colspan="2" style="border-left:2px solid #2a6fdb;border-right:2px solid #2a6fdb;border-top:2px solid #2a6fdb;border-bottom:none;padding:0.4em 0;">(F6)</td>
  <td colspan="1"></td>
</tr>
</table>

DPS Keyboard Unit buttons are mapped to regular keyboard keys (mapped key in parenthesis):

|                              |                            |                               |                       |
| :--------------------------: | :------------------------: | :---------------------------: | :-------------------: |
| <sub>(u)</sub><br>FAULT SUMM | <sub>(y)</sub><br>SYS SUMM | <sub>(esc)</sub><br>MSG RESET | <sub>(k)</sub><br>ACK |
|  <sub>(g)</sub><br>GPC/CRT   |             A              |               B               |           C           |
| <sub>(t)</sub><br>I/O RESET  |             D              |               E               |           F           |
|    <sub>(i)</sub><br>ITEM    |             1              |               2               |           3           |
|  <sub>(enter)</sub><br>EXEC  |             4              |               5               |           6           |
|    <sub>(o)</sub><br>OPS     |             7              |               8               |           9           |
|    <sub>(s)</sub><br>SPEC    |             -              |               0               |           +           |
|   <sub>(r)</sub><br>RESUME   | <sub>(bksp)</sub><br>CLEAR |               .               | <sub>(p)</sub><br>PRO |

The major function switch is `<` GNC, `>` SM and `?` PL.

Keystrokes go to the IDP commanding the window's MDU, over the keyboard
the IDP/CRT SEL switches have on that IDP: the left keyboard is wired to
IDP 1 and IDP 3, the right to IDP 3 and IDP 2, the aft to IDP 4.  `[` throws the LEFT switch between 1 and 3, `]`
the RIGHT between 2 and 3 (`meds/idp/idpSel.coffee`); the red and yellow
bars beside the IDP box on the DPS display follow them.  With no keyboard switched to an IDP its
windows drop their keystrokes.


Debug tools: The `--dev` option enables a standalone development
mode that enables tools for refining the drawing and display features
of the software.  In `--dev` mode the displays start on sample values:
the PFD on an entry attitude with its tapes and mode filled in, the
gauges, the SPI and the fault summary on sample data.  A double-click
outside of the canvas enables a debug pane that lets you manually set
ADI values or enable test sweeps.  The DPS display adds hotkeys to load
local test dfbs.  `--dev` mode also disables the DPS poll timeout;
normally you'll get the big-red-X and a 'POLL FAIL' message on the DPS
screen without a stream of polls.

Started normally every instrument shows its invalid indication until
data arrives: the ADI's OFF flag with its needles and pointers stowed,
the tapes as red boxes, the meter without a needle, the mode and DAP
fields blank, the gauges red, the SPI outlined red without pointers and
the fault summary empty.  The DDU words and the MEDS transfer on the FC
busses fill the PFD (the DDU section below), the ADC frames the gauges
and the SPI.

### gpcmd — simulated GPC command traffic

`gpcmd` puts that traffic on a bus itself, standing in for a GPC:
the same commands in the same two-halfword form, with data one 
halfword at a time.

```
gpcmd monitor                              # decode every bus, both ways
gpcmd monitor DK1 --fcw                    # ... disassembling the formats
gpcmd unit --idp 1                         # BE a display unit, headless
gpcmd unit --ipl-request --fcw             # ... and ask to be loaded
gpcmd key SPEC 2 PRO --idp 1               # press keys on a unit's keyboard
gpcmd mf SM --idp 1                        # move its major function switch
gpcmd idpsel 3 2                           # LEFT IDP/CRT SEL to 3, RIGHT to 2
gpcmd idpsel                               # ask the IDPs where the switches are
gpcmd idpload 2                            # IDP 2's LOAD momentary
gpcmd fill data/TEST-9011-GPC_MEMORY.dfb   # display data fill
gpcmd fill f.dfb --addr 19EE --format      # ... as a format data fill
gpcmd time --interval 1                    # the MET/CRT header clock
gpcmd time --met 2/03:45:00 --interval 1   # ... starting at a given MET
gpcmd poll --interval 1                    # poll, and print the response
gpcmd bite                                 # BITE status request
gpcmd resetspl                             # clear the scratch pad line
gpcmd raw 71800 0001 19EE                  # a 19-bit command + payload
gpcmd watch DK1                            # decode traffic on a bus
```

A fill clears the DPS display's POLL FAIL state, and the header clock
takes over from the IDP's local one as soon as any command arrives.

`monitor` is the one to reach for first.  A raw word dump is nearly
useless on this bus -- a transaction is a command datagram and the data
words behind it, and the meaning is in the reassembly -- so
it rebuilds each transaction and prints one line per message with the
fields decoded: fill address and length, poll response header flags and
keystrokes by name, checksum verified.  `--fcw` disassembles a fill
payload as display instructions, which is how you see what a format
actually draws; `--json` writes a record per message for later analysis.

`unit` is a display unit with no window, running the SAME protocol state
machine the MEDS IDP runs (`meds/deu/deuUnit.coffee`), with its own keyboard
on `_KYBDn` so `gpcmd key` reaches it.  It is the fast way to drive
flight software and see exactly what it sent: `--ipl-request` asks the GPC
to load the unit, `--no-bite` answers with a zero BITE register (which is
what a GPC reads as no response at all), and `--dump` writes display
memory out on exit.

LRU — one command for the units
-------------------------------

`lru` runs one or more device models and exposes their subcommands.
Definitions are in `src/lru/<name>/spec.coffee`.

```
lru list                             # the catalog
lru run imu                          # one unit, as `imu run` does
lru run imu + mtu + mdm FF1          # three units in this process
lru run mdm FF1 + mdm FF2 -q         # the same kind twice
lru mdm cards FF1                    # a unit's own subcommands
```

`+` separates units. Options before the first unit apply to the process;
each segment takes that unit's `run` options.

MMU — Mass Memory Unit
----------------------

`mmu` runs a mass memory unit on its bus and answers a GPC.

```
mmu run --unit 1 --volume tape.mmv   # serve a tape on MM1 (BCE 18)
mmu create tape.mmv                  # an empty volume
mmu put tape.mmv 0/0/0/0 data.bin    # lay halfwords on the tape
mmu get tape.mmv 4/4/3/8 --blocks 17 # read them back
mmu ls tape.mmv                      # what a volume holds
mmu dump tape.mmv 4/4/3/8            # hex dump one block
mmu watch MM1 --decode               # decode the bus traffic
mmu send MM1 588000                  # put one command on the bus
```

MDM — Multiplexer/Demultiplexer
-------------------------------

`mdm` runs a catalog unit on its two flight busses and `_<id>_mdmIO`
hardware-side bus. Catalog: `mdmConfig.coffee`; protocol: `mdmConf.coffee`;
PROM programs: `prom.coffee`.

```
mdm run FF1                          # MDM FF1 on FC1 and FC5, IUA 10
mdm run FA1 --mdm                    # as an original MDM, not an EMDM
mdm list                             # the catalog
mdm cards FF1                        # the card in each slot
mdm prom FF1                         # the PROM programs it runs
mdm io FF1 set 4/0 8000              # discrete 1 of card 4 channel 0 on
mdm io FF1 value 1/3 --volts 2.5     # an analog input
mdm io FF1 connect 3/0               # a serial device is on the IMU channel
mdm io FF1 disconnect 3/0            # ... and unplugged again
mdm io FF1 request '2/*'             # what the GPC has set an output card to
mdm io FF1 watch --volts             # the hardware side traffic
mdm watch FC1 --decode               # the flight bus traffic
mdm send FC1 518000                  # the return word command, by hand
```

A serial read with no connected response returns E on every word. Responses
begin 33.5 µs per requested word after the command.

A reply from an MDM crosses two host processes and takes hundreds of
microseconds of wall time, where the flight software budgets tens for
the wire: it leaves the flight critical bus receive timeout at 2 counts,
33 us, and times every transaction from a table of 34 us a word plus
overhead.  A real-time paced GPC therefore holds simulated time still
while a reply is owed on a bus something has answered on before, for up
to `NSTS_BUS_STALL_MAX_MS` of wall time (20 ms; 0 turns it off), so the
reply lands as it would over the wire.  `config/sim.yml` also sets
`NSTS_RECV_TIMEOUT_FLOOR_MS=10` for the `gpc` and `gpcdbg` entries, a
floor that applies on a bus something has answered on: a display bus with
no unit on it runs out at the 5.0 ms the software loads there and the
element error terminates.
`NSTS_BUS_TIMEOUT_TRACE=1` prints every receive timeout to the GPC's log
with the timeout in force.

MTU — Master Timing Unit
------------------------

`mtu` runs three GMT/MET accumulators behind FF1–FF3 and the voted and
non-voted instrumentation outputs behind OF1 and OF2. Formats, wiring,
and command words are in `lru/mtu/mtuConf.coffee`.

```
mtu run                            # three accumulators, GMT from the host clock
mtu run --gmt 052:14:30:00         # start at a given GMT
mtu run --accum 1 --met 3/01:02:03 # one accumulator, a given MET
mtu run --skew 2=+0.9 --fail 3     # one off by 0.9 ms, one silent
mtu run --disconnect 2             # one unplugged from its MDM channel
mtu read 1                         # read accumulator 1 through MDM FF1 on FC1
mtu watch 1                        # the polls and answers behind FF1
mtu watch oi1                      # ... behind OF1, the voted output
mtu run --oi none                  # accumulators only
mtu time 052:14:30:00.125          # the three halfwords for a time
mtu commands                       # the command words a GPC uses
```

IMU — Inertial Measurement Unit
-------------------------------

`imu` runs three HAINS units behind FF1–FF3, serial I/O card 3 channel 0.
Resolver angles, accelerometer counts, and redundant-axis rate are not
modeled. Formats and wiring are in `lru/imu/imuConf.coffee`.

```
imu run                            # three units behind FF1/FF2/FF3
imu run --units 1,2                # two of them
imu run --fail 2=PLATFORM_FAIL     # a mode status BITE in one unit
imu run --silent 3                 # one that hears its poll and says nothing
imu run --disconnect 1             # one unplugged from its MDM channel
imu read 1                         # read IMU 1 through MDM FF1 on FC1
imu watch 1                        # the polls and answers behind FF1
imu status                         # the mode status word, bit by bit
```

ADTA — Air Data Transducer Assembly
-----------------------------------

`adta` runs four units behind FF1–FF4, serial I/O card 11 channel 1.
Pressure and temperature conversion is not modeled. Formats and wiring
are in `lru/adta/adtaConf.coffee`.

```
adta run                           # four units behind FF1/FF2/FF3/FF4
adta run --fail 3=PS_GOOD          # a mode status BITE in one unit
adta run --self-test 1=high        # the high self test in force
adta read 1                        # read ADTA 1 through MDM FF1 on FC1
adta watch 1                       # the polls and answers behind FF1
adta status                        # the mode status word, bit by bit
```

NSP — Network Signal Processor
------------------------------

`nsp` runs two Network Signal Processors behind FF1 and FF3 and the
`_SBAND_FWD` PCM stream. The radio path is not modeled; `nsp uplink`
generates its output directly. Protocol and BCH formats are in
`lru/nsp/nspConf.coffee`.

```
nsp run                            # NSP 1 powered behind FF1, NSP 2 off behind FF3
nsp run --power 2 --rate hdr       # NSP 2 instead, on the high data rate
nsp run --uplink-switch nsp-block  # the panel C3 switch
nsp uplink 4f17 a801 0001          # one command word up the link, three halfwords
nsp uplink $(nsp rtc FF1 10/0 set 0001)   # a real-time command to a discrete output
nsp uplink --errors 2 4f17 a801 0001         # one that fails the BCH check
nsp carrier                        # the idle stream, until ^C
nsp read 1                         # read NSP 1 through MDM FF1 on FC1, as a GPC does
nsp watch 1                        # the polls, answers and discretes behind FF1
nsp watch link                     # the forward link, frame by frame
nsp word --vehicle 2 --mf GNC --opcode 69 a8010001   # a command word from its fields
nsp bch 4f17 a801 0001             # the 77 parity bits of a command
nsp commands                       # the MDM command words a GPC uses
```

ADC — MEDS Analog to Digital Converter
--------------------------------------

`adc` runs four 1553B remote terminals, each sampling 32 inputs at 25 Hz.
`adc drive` supplies modeled signal-conditioner inputs. Formats are in
`adcConf.coffee`; the JSC-18819 SCP 4.9 channel table and MDM routes are
in `adcChannels.coffee`.

```
adc run                            # ADC 1A, 1B, 2A and 2B
adc run --units 1A,2A --fail 2A    # two units, one that hears and does not answer
adc run --cst-result 1A=0010       # a self-test that fails the +5.6 V reference
adc drive 1                        # pair 1's conditioner signals at nominal values, until ^C
adc drive 2 --sweep                # pair 2's meters sweeping their scales
adc drive 1 --sweep --all          # ... the GPC's channels too, on the analog bus
adc drive 1 --set omsHeTKP_L=4100 --set omsPcL=100
adc set 1 omsHeTKP_L --eu 4100     # one channel, in engineering units, on FA1 card 6 channel 17
adc set 2 15 2.5                   # ... or a channel number, in volts
adc set 1 V72H5106C 2.5 --direct   # a GPC channel forced on the analog bus
adc poll 1A                        # read a unit's frame as its IDP does
adc status 1A                      # the status block: BITE, CST, sample count
adc cst 1A                         # start the self-test and read the result
adc watch 1A                       # the 1553B traffic to and from a unit
adc watch _IDP1                    # ... every ADC on IDP 1's bus
adc watch analog 1                 # the signals on pair 1's inputs
adc channels 1                     # the channel table of a pair: signal, MSID, source, tap
adc commands                       # the command words an IDP uses
```

DDU — the flight instruments on the FC busses
---------------------------------------------

`ddu drive` supplies ADI, HSI, AMI, AVVI, and MEDS-transfer messages on
one or all FC busses. Command and data formats are in `dduConf.coffee`;
`dduFields.coffee` maps received words to PFD fields.

```
ddu drive FC3                      # MM 305 held on FC3, until ^C
ddu drive all --ramp               # every bus, every quantity sweeping
ddu drive FC3 --mm 103 --abort TAL --set adiPch=60 --set mach=12.5
ddu drive FC3 --off ADI.rollRate --off AVVI.altitude   # a stowed pointer, a red box
ddu drive FC3 --ddu 2 --no-meds    # DDU 2 alone
ddu watch FC3                      # the DDU and MEDS traffic, decoded
ddu watch FC1 --raw --msg ADI      # ... one message, in hex
ddu words hsi                      # a message's word table and command payload
ddu decode avvi f800 aaa9 0f00 ... # words given by hand
ddu fields                         # the drive's fields, defaults and ranges
```

sim — running a configuration
-----------------------------

A simulation is several processes: at least a GPC, a MEDS display and an
MMU serving the software.  `sim` configures a set of them and manages
their lifecycle together.

```
sim                          # open mgr; start a detached master if needed
sim start                    # headless master, initially idle
sim start --autostart        # master with the configured autostart set
sim run --restore "IPL GPC 1" # start checkpoint LRUs and restore, held frozen
sim start --restore "IPL GPC 1" --resume # restore, then RUN automatically
sim mgr                      # attach a frontend; quitting leaves the sim running
sim run mmu1 gpc4            # master that starts only these processes
sim list                     # discover running simulations
sim status                   # process state from the master
sim inspect                  # configuration, components, buses and errors as JSON
sim start mmu1               # start a configured process
sim stop mmu1                # stop it; the master remains available
sim restart mmu1             # restart it through the master
sim logs mmu1                # recent process output
sim terminate                # stop every process; keep the master available
sim catalog                  # what is in the run configuration
sim config                   # the configuration as sim resolved it
sim -r config/entry.yml start # start a different configuration
sim --base-port 7100 start   # a second simulation with a separate bus block
sim --base-port 7100 mgr     # attach to that simulation
sim doctor                   # every simulator process, by base port
```

Startup `--restore NAME` looks under the selected run configuration's dstore
root, using the same names as `sim dstores`. It starts the processes recorded
in the checkpoint, including those not marked for autostart, waits for all
embedded LRUs to announce, then performs FREEZE and validated RESTORE.
Use the same configuration and compatible LRU builds as the saved session.
The session stays frozen unless `--resume` is supplied. Startup restore has
a five-minute timeout; failures print diagnostics, stop the new session, and
exit nonzero. These options create a new master and cannot be combined with
individual LRU arguments. Attach with `sim mgr` in another terminal.

Run `sim start` and the frontends in separate terminals, or use plain `sim`
to launch both. Without an explicit `--host` or `--base-port`, `mgr` reuses
the default master or starts a detached one. Explicit endpoints attach only.
Detached master output goes to `master-<port>.log` in the configured log directory.
Several frontends may
attach to one master. SIGINT or SIGTERM to the master stops its processes.
Each simulation needs a nonoverlapping bus-port block and separate debugger
ports in its run configuration. The default `sim` command attaches a frontend.

Discovery uses UDP; queries and lifecycle commands use TCP at the simulation's
base port. The control protocol and environment settings are in
`src/simMgr/controlbus.py`. Connections default to loopback and have no
authentication: use a trusted network. `--host` selects a master's address.
Process launch runs on the master's machine.
Remote frontends show process state and logs; cockpit pages use loopback
connections and are available when attaching to a loopback master.

The manager and `test/sim/control.cjs` use Python with `pyyaml` and `typer`.
`NSTS_SIM_PYTHON` selects the interpreter.

`doctor` walks the process table rather than the supervisor's own record, so
it sees a session driven by hand and one left behind by a previous run.  Two
LRUs of the same identity on one base port answer the same commands — a
second MMU1 on MM1 stops a GPC's IPL — and it flags them and exits non-zero.

A GPC in a configuration runs on a debug socket (`dbg-serve --autostart`),
so `gpc dbg --port 4444` attaches to the running machine to
break, trace or read memory.  The `dbgport` param sets the port; the
default configuration has GPC n on 444n.  GPC 4 IPLs from MM1 and takes
the IPL menu on CRT 1; GPCs 1, 2, 3 and 5 are the catalog's `gpchalt`,
powered with the mode switch at HALT (`--mode halt`) and nothing loaded,
so they answer on the inter-GPC discrete lines and the GPC STATUS page,
and are IPLed one at a time from it: mode HALT, the IPL pushbutton, mode
STBY, then IDP 1's LOAD momentary, which is what has GPCIPL load the
display and draw its menu on CRT1; ITEM 1 EXEC on the menu loads the
PASS, and mode RUN starts it.  The default configuration starts IDP 1
asking for its load, so GPC 4's IPL reaches the menu unattended.

`config/sim.yml` is the LRU catalog: what kinds there are, the command that
runs one, where its files live, and how to tell whether it is up.
`config/runConfig.yml` is the configuration being managed: which LRUs, in
what order they come up, and what each is given.  Both are commented, and
`sim config` shows them resolved.

The default SUMMARY page places grouped LRU status on the left and GPC
STATUS on the right. F6 cycles the right pane through GPC STATUS, the
detailed LRU table, and PANEL. F7 switches keyboard focus between panes;
on terminals too narrow for both, it switches the visible pane.
Pane widths follow the grouped LRU content; commands and simulator status
span the page.
The standalone views are retained through `App(combined_summary=False)`.
The LRU summary groups short names by hardware type. Arrows
select a name, its control-bus indicator, bus activity, or log spinner.
Enter on the name, bus activity, or spinner opens operations, sampled
bus traffic, or the log. Detail views overlay the right pane; Escape
returns to the preceding view. Tab selects the global commands.
Bus arrows indicate receive (left) and transmit (right); the cyan log
spinner advances one step per log line, including lines received between
refreshes. Empty indicators are grey dots. Spinner activity requires master
snapshots containing log counts.
The header shows the configuration, wall time, elapsed master time, state
and health.

Bus traffic contains bounded packet-prefix samples from each component's
UDP or shared-memory buses, excluding `_simControl`. Power and panel buses
use a darker blue; direct buses retain the brighter activity color.
Processes without component telemetry show
their process state and logs, with no advertised bus data.

GPC STATUS is the panel O1 status matrix, panel O6's controls for
GPCs 1 to 5 -- the OUTPUT talkback and switch, the IPL pushbutton, the
MODE talkback and switch -- the IPL SOURCE and BFC CRT switches, and a
table of every GPC's discrete lines, read from each GPC's debug socket
(`debugPort` in `config/sim.yml`) four times a second.  A column belongs
to the GPC whose ID lines carry its number (`--gpc`), and a GPC that is
not answering is a dark column.  A GPC that answers with no MODE position
set is put at STBY.  Enter on an input line toggles it, as `gpc discretes
set` would; on a sync code or the GPC ID a digit sets the value.  Lines
set from the page are underlined.  At the right of the page are the IDP
switches, driven on the IDPs' discrete channels: the LEFT and RIGHT
IDP/CRT SEL switches, the four IDP LOAD momentaries, and each IDP's
lines; an IDP that is not answering is dark.

`test/sim/selftest.yml` is four synthetic LRUs, for exercising the supervisor
while a real session is running:

```
sim --base-port 7300 -c test/sim/selftest.yml -r test/sim/selftest-run.yml start
sim --base-port 7300 mgr
```

Each LRU's output is appended to `run/logs/<lru>.log`.

PCMMU — PCM Master Unit
-----------------------

`pcmmu` runs two PCM Master Units: five GPC IP interfaces, OI MDM fetch,
toggle buffers, and 128/64-kbps telemetry streams. Protocol and memory
layouts are in `pcmmuConf.coffee`; derived fetch and format programs are
in `fetch.coffee` and `tlmFormat.coffee`.

```
pcmmu run                          # PCMMU 1 powered, FORMAT switch at GPC, PROM 129
pcmmu run --power 2 --format-switch fixed
pcmmu run --hdr-format 161 --ldr-format 103   # the format RAMs preloaded
pcmmu watch gpc 4                  # GPC 4's commands on IP4, each downlist frame decoded
pcmmu watch hdr --every 25         # the 128 kbps stream, minor frame by minor frame
pcmmu watch oi 1                   # the fetch on OI1
pcmmu read --gpc 5 7 7             # read the OI/PL RAM on a spare GPC bus, as a GPC does
pcmmu bite --gpc 5                 # the BITE register, bit by bit
pcmmu tb --gpc 5 1 0 8             # toggle buffer 1, the formatter's side
pcmmu map OF1                      # the fetch program's RAM map
pcmmu formats                      # the format library and its windows
pcmmu commands                     # the command words a GPC uses
```

A read tool must use an IP bus with no running GPC.

ratsnest — the wiring between the units
--------------------------------------

`ratsnest` is the wiring simulator. It loads specifications, joins their
busses, evaluates nets, and publishes changed outputs.

A specification is one or more `wiring` units in VHDL's grammar, with
entity and architecture dropped and the binding written where a port is
declared:

```vhdl
wiring adi_left is
  type attitude is (INRTL, LVLH, REF);
  port (
    att       : in  attitude bind panel "F6/S3";
    pwr_a     : in  logic    bind mdm   "FF1/6/0.0";
    att_inrtl : out logic    bind mdm   "FF1/4/1.0"
  );
  signal powered : logic;
begin
  powered   <= pwr_a;
  att_inrtl <= powered and att = INRTL;
end wiring;
```

The types are `logic`, `word`, `integer`, `real` and any enumeration a
unit declares; the operators and their precedence are VHDL's, with
`x <= a when c else b` for a choice; `latch`, `pulse`, `delay` and
`falling` hold state between evaluations.  Five schemes bind a port:

```
panel     <panel>/<control>              F6/S3
mdm       <unit>/<card>/<channel>[.<bit>]  FF1/4/1.0
discrete  <device><n>/<register>/<bit>   gpc4/A/mm1ready
adc       <pair>/<channel>               1/12
power     <feed>[.draw]                  MNA, MNA.draw
```

An output is withheld until each of its inputs has answered. Missing inputs
are requested every two seconds.

Specifications are in `config/wiring/`; the parser, evaluator, and binding
schemes are in `src/ratsnest/`.

```
ratsnest run                       # every config/wiring/*.wir
ratsnest run config/wiring/gpc.wir -v     # one file, a line for every net that moves
ratsnest check                     # read the wiring and report what is wrong
ratsnest show --drivers            # the nets and what drives them
ratsnest set O6/S46 RUN            # put one control on the panel bus
ratsnest watch --discrete gpc1     # the traffic on a bus the wiring reaches
ratsnest watch --power             # the feeds and the loads on them
ratsnest schemes                   # the binding schemes and their addresses
```

panel — the crew panels
-----------------------

A panel control is keyed by panel name and the control ID shown in
USA-007587 appendix A, such as `O6/S46` or `O6/DS8`.

`config/panels/*.yml` defines controls, positions, and layout. The panel-bus
implementations are `panel/panelBus.coffee` and `simMgr/panel/bus.py`.

The text frontend is available in `sim` or separately:

```
python3 -m simMgr.panel                  # every panel in config/panels
python3 -m simMgr.panel O6 F6            # two of them
python3 -m simMgr.panel --list           # the panels there are
```

power — the dc distribution and what hangs on it
-----------------------------------------------

Power feeds are voltage nodes published by the wiring simulator on `_POWER`.
Units subscribe to their configured feeds and publish their load.

```
                 panel R1, O6, O13, O14, O15
                            |
                     ratsnest, config/wiring/eps.wir
                            |
   MNA MNB MNC  ESS1BC 2CA 3AB  CNTL_AB1..CA3  GPC1_A..GPC5_C  MMU1 MMU2 ...
                            |
       GPC   MMU   MTU   MDM   IDP   MDU   ADC   PCMMU   NSP
```

`config/wiring/eps.wir` is the distribution as USA-007587 sect.2.6 and the panel
diagrams give it: the fuel cells onto the main busses through FC/MAIN
BUS, the MN BUS TIE contactors, the essential and control busses, three
remote power controllers a computer behind the O6 GPC POWER switches, the
MMU switches on O14 and O15, the MTU breakers on O13, and the FLT CRIT
switches on O6.  Throw `R1/S10` to OFF and main bus A goes, taking one
controller of every computer, MMU 1, and any MDM with no other bus; tie A
to B and it comes back.

A unit's `power` entries combine according to `powerRule`: `any` or `all`.
An input is dead below its dropout voltage.

`--power-default` sets the value before a feed answers: `on`, `off`, or a
voltage. `NSTS_POWER_DEFAULT` sets the session default.

The protocol and `PowerSupply` are in `com/power.coffee`.

```
ratsnest watch --power             # every feed and every load
sim                                # p to the PANEL page: R1, O6, O13, O14, O15
mdm run FF1 --power-default off    # a unit that starts dead
```

Repository Contents
-------------------

The tree is `src/` for everything the simulator is made of, `cmake/` for
everything that builds it, and `config/`, `data/`, `test/` and `tools/`
beside them.  `test/` mirrors `src/`, so a ctest name is a path in it --
`ctest -R '^lru/'` runs the units.  `build/` is the cmake build tree.

  - `src/simRunner/` contains the Electron main & renderer process implementation (now in [civet](https://civet.dev/), a TypeScript dialect).  `gpc gui` serializes its parsed CLI options to a base64 blob passed via `--cli-opts=…` to Electron, which `simRunner/main/main.civet` decodes on startup.  We use Electron only for the GUI debugger; the batch, REPL, dump, and disasm subcommands run as a plain node bundle (`build/dist/gpc.js`).

  - `src/com/` contains common utilities, including a simple 'Bus' that lets LRUs communicate via multicast UDP packets.  In the gpc it's used to emulate the physical Shuttle busses connected to the IOP; MEDS uses the same busses for IDP↔MDU and (eventually) GPC↔IDP traffic.

| Directory | Model |
|---|---|
| `src/lru/adc/` | MEDS Analog to Digital Converter |
| `src/lru/adta/` | Air Data Transducer Assembly |
| `src/lru/ddu/` | Flight-instrument output on the FC busses |
| `src/lru/imu/` | Inertial Measurement Unit |
| `src/lru/mdm/` | Multiplexer/Demultiplexer |
| `src/lru/mmu/` | Mass Memory Unit and tape volumes |
| `src/lru/mtu/` | Master Timing Unit |
| `src/lru/nsp/` | Network Signal Processor and forward link |
| `src/lru/pcmmu/` | PCM Master Unit and telemetry streams |

  - `src/ratsnest/` routes signals between the busses:
    - `wiring.coffee` (the wiring language: its grammar and its built-in
      functions are in the header),
    - `netlist.coffee` (the nets, the drivers, and the settle),
    - `adapters.coffee` (the panel, mdm, discrete, adc and power bindings),
    - `ratsnest.coffee` (the process: loading, publishing and the clock),
    - `cli.coffee` (the `ratsnest` command).
  - `config/wiring/` holds the specifications, `src/panel/panelBus.coffee` the panel
    bus message and `com/power.coffee` the power bus message;
    `config/panels/` holds the panels.

  - `src/simMgr/` is the supervisor behind `sim`, in Python:
    - `config.py` (the two YAML files, resolved into what is actually run),
    - `process.py` (one child: its process group, its signals, its output),
    - `health.py` (the probes that decide whether a running LRU is well),
    - `supervisor.py` (the ordered start, the restart policy, the terminate),
    - `screen.py`, `views.py` and `tui.py` (the curses interface),
    - `controls.py` (talkbacks, switches, pushbuttons, lights, and the
      cursor over them), `gpclink.py` (a GPC's debug socket),
      `discretebus.py` and `idplink.py` (the IDPs' discrete channels) and
      `gpcview.py` (the GPC STATUS page),
    - `panel/` (the crew panels: `bus.py` the `_PANEL` datagram,
      `catalog.py` the panel files, `link.py` this process's end of the
      bus, `view.py` the page, `__main__.py` the standalone command),
    - `cli.py` (the `sim` command, on typer).
  - `config/sim.yml` and `config/runConfig.yml` are what it reads;
    `test/sim/selftest*.yml` are synthetic LRUs for trying it.
  - `src/meds/` contains the MEDS simulator:
    - `mdu/mdu.coffee` (display unit),
    - `idp/idp.coffee` (the Integrated Display Processor, a process with no window),
    - `idp/idpAdc.coffee` (the IDP's bus controller toward its ADCs, and the frame message to the MDUs),
    - `idp/idpFc.coffee` (the IDP's receiver on the FC busses for the DDU writes and the MEDS transfer, and the message to the MDUs),
    - `idp/idpSel.coffee` (the IDP/CRT SEL switches and the keyboards they route),
    - `idp/idpDiscretes.coffee` (the IDP's discrete lines: the KYBD SEL and LOAD inputs, the load state, and the panel that drives them),
    - `idp/cli.coffee` (the `idp` command),
    - `deu/` is the DEU itself: `deuProto.coffee` (the display-keyboard bus
       protocol), `deuFCW.coffee` (Format Control Word specification -- the
       DEU's drawing language), `deuUnit.coffee` (the state machine a GPC
       polls), `deuSPL.coffee` (the scratch pad line) and
       `deuSelfTest.coffee` (the stand-alone self test),
    - `mdu/` is the display unit: `mduScreen_*.coffee` (the individual
       displays, `_DPS` among them), `mduVectorDisplay.coffee` (Three.js
       vector renderer), `mduMenu*.coffee` and `mduEdgeKeys.coffee` (the
       menu area and its keys), `shader/` and `style.css`,
    -  `medsConf.coffee` (the orbiter's MDU/IDP/bus wiring).

  - `tools/deu/` reads and writes the display-format binaries in `data/`:
    -  `dfbDump.coffee` prints a format control word stream,
    -  `dpsDispToFcb.coffee` compiles a DPS display mock-up into one,
    -  `fcwCal.coffee` measures the beam grid a stream is written on -- the
       character and vector lattices, and which wrap the stream will fit
       into.  Use it before changing the constants in `meds/deu/deuFCW`.

    `./BUILD.sh dfbDump-bundle` and friends build them; each runs as
    `node build/dist/<name>.js <file.dfb>`.

  - `config/meds.json` defines the launchable MEDS LRUs; `data/` holds the DEU/MEDS vector fonts and sample DFB files.

  - `src/cde/` contains definitions of [Lit gui elements](https://lit.dev/), including the toplevel `<cde-window>` that styles the window to the CDE look and feel.  There's no
  compelling reason to have this, other than CDE shows up quite a bit in Shuttle documentation from the 1990's and 2000's--and I think it looks neat.

  - `cmake/` holds the build.  `cmake/esbuild/bundle.js` bundles one named CLI entry point; `cmake/esbuild/{main,renderer}.config.ts` are the Electron halves, driven by electron-esbuild from the build tree.  `cmake/templates/` carries the command wrappers and the two generated configs; `cmake/*.cmake` the targets.

  - `src/gpc/` contains the simulated AP-101 definition
    - `src/gpc/asm` holds `fakeipl.asm`, the IPL stand-in, beside the image and listing the cmake build assembles from it.
    - `src/gpc/dbg` contains the debugger: the session, the socket server and client, the command table and the bus/discrete monitors.  `gpc/dbg/sym` holds the symbol tables and the SDL index over a loaded image; `gpc/dbg/fcos` reads the flight software's process state and the memory configuration in storage.
    - `src/gpc/gui` is the Electron debugger's front end: `gui.coffee` (the window),
      `guimirror.coffee` (the session state its panes read), `guibackend.coffee`
      (the session behind it), and `widgets/` (the Lit elements the panes are built from).
    - `runharness.coffee` runs the machine for every debug session, with pacing, interrupt controls and progress callbacks.
    - `src/gpc/cmd` holds one `cmd_*.coffee` per subcommand of the `gpc` command.
    - `cli.coffee` is the unified entry point, dispatching to one of `cmd/`'s files.
    - `ap101.coffee` is the definition of the GPC LRU.
    - `cpu.coffee` implements the AP-101's CPU
      -  `cpu_instr.coffee` CPU instruction definitions.
      -  `cpu_intr.coffee` CPU interrupt handling routines
    - `iop.coffee` and `iop_*.coffee` implement the IOP half of the AP-101
      - `iop_msc_*.coffee` is for the IOP Master Sequence Controller (MSC)
      - `iop_bce_*.coffee` is for the many IOP Bus Control Elements (BCE)
    - `mcm.coffee` implements the Modular Core Memory (a.k.a. the RAM)
    - `membus.coffee` routes memory accesses to either the CPU or IOP package depending on address (matching AP-101B behavior).
    - `regmem.coffee` implements the registers and PSW.
    - `q31.coffee` implements Q31 / Q15 fractional fixed-point arithmetic, used by the fractional multiply/divide instructions.
    - `floatIBM.coffee` implements IBM hexadecimal floating point (with `long.js` for 56-bit mantissa precision in the double-precision paths).
    - `halUCP.coffee` implements basic (IBM style) file I/O expected by the HAL/S runtime when running in the mainframe-based SDL environment.  Useful for testing, not available in the flight configuration.  (Named after the S/360 'HAL/S User Control Program' simulator.)
    - `iohost.coffee` provides the host-side glue for `halUCP` channels (file/stdin/stdout/interactive).
    - `ebcdic.coffee` and `util.coffee` are utilities used by other parts of the simulator.

Development Notes
-----------------

  - The GPC simulator (and larger sim environment it's pulled from) was written over a long period of time and exhibits some strange patterns because of it.  The nodejs/electron/coffee setup allowed very fast iteration.  Today, starting from scratch, I would not choose the same environment.

  - electron was a very fast way to iterate on graphical tools for debugging (and WebGL based displays for e.g., MEDS). While it's still pretty good for that, changes in how it handles the separation between the main and rendering process have made it much less convenient to work with.

  - coffeescript is a terse, easy to read alternative to base javascript.  Unfortunately, it's been largely abandoned for years.  I've had to convert some files to typescript and even tried civet--a coffeescript-like dialect for typescript--for the Electron host.  Future work will likely be in typescript.

  - A rewrite of the AP-101 simulator in C using the SIMH framework is in progress.

AP-101 Implementation Notes
---------------------------

  - This implementation is at an *instruction* level and simulates approximate timing, based on timing data in the Principles of Operation (B & S).  Most internal microstate isn't modeled, except where it's required for things like DIAG instructions.

  - The implementation is very verbose.  I've copied blocks of the POO directly into the comments and used it to guide the implementation.  Instruction opcode patterns and decoding is defined using bit strings (like '00011xxx11100yyy'), and additional format information is attached to make disassembly easier.  The intent is to make it as simple as we can to understand what the processor is doing and locate any errors in our logic.  Once verified, converting this to a much terser decoding process would make sense.

  - We model both the AP-101B model originally installed in the Shuttle and the AP-101S upgrade.  We default to AP-101S mode.

  - The simulator includes an implementation of the IOP coprocessor used to interface to the 24 serial shuttle busses.  Verification is still in progress, but it's known to be able to communicate with the MEDS and MMU implementations also in this repository.

References
----------
IBM-74-A97-001 1975-03-31
Space Shuttle Advanced System/4 Pi |
Model AP-101 Central Processor Unit | Technical Description

IBM-74-A31-016 1974-10-25
Space Shuttle Advanced System/4 Pi |
Prototype Input/Output Processor (IOP) | Functional Description

IBM-85-C67-001 Rev.F 1994-07-12
Space Shuttle Model AP-101S
Principles of Operation with Shuttle Instruction Set

IBM-6246156B 1974-12-15
Space Shuttle Model AP-101 C/M Principles of Operation

IBM-6246556A 1976-04-26
Space Shuttle Advanced System/4 Pi Input/Output Processor (IOP) |
    Principles of  Operation for PCI/PCO, MSC and BCE

### Freeze and named datastores

After updating simulation-control code, restart the background manager and
LRUs. Reopening `sim mgr` only reattaches the terminal; it does not reload
the background manager. An older manager shows simulation control as
unavailable until restarted.

The manager's **SIMULATION** right-hand view (F6 cycles right views; F7
moves focus) has **FRZ**, **RUN**, **FREEZE AT**, **DSTORE**, **RESTORE**,
and **RENAME** controls. Enter activates a control; Escape cancels name
entry. Select a named store before restoring or renaming it. PgUp/PgDn
scroll the controls and per-LRU results in a short terminal.

FRZ/FREEZE holds simulation timers, paced GPC execution, bus deliveries,
and hardware input. Discovery, reports, and datastore commands remain
available. RUN continues the pending work and excludes the frozen interval
from the LRUs' clocks, rather than making timers catch up. Automatic LRU
restarts are held too. Process changes require RUN; stopping a process is
still available while frozen.

FREEZE AT takes seconds on the manager's session clock, which advances
while running and stops while frozen. Freezing is cooperative: each process
stops at its next event-loop boundary, and the manager reports **frozen**
only after every active managed component has acknowledged completion.
This is not an instruction-exact common GPC cycle breakpoint. A missing,
old, or unresponsive component prevents a successful freeze.

Freeze before saving or restoring. By default a run file `config/run.yml`
owns `config/run/dstore/`. Set `paths.dstore` in the run configuration to
choose another root. Each name creates a separate directory:

```text
config/run/dstore/
  before-ipl.dstore/
    manifest.json
    gpc1/state.json
    gpc1/runtime.json
    mmu1/state.json
    mmu1/runtime.json
  after-ipl.dstore/
    ...
```

An embedded process containing several LRUs gets subdirectories under its
configured process key. Store names may contain letters, digits, spaces,
periods, underscores, and hyphens (for example `IPL GPC 1`). Do not include
the `.dstore` suffix. Stores never overwrite an existing name. A failed
save remains marked incomplete and cannot be restored. Commands are retried
with the same identity; each LRU reports receipt and then completion or an
error. Restore checks every LRU before applying any saved state, and leaves
the simulation frozen. A failure during application leaves an error state;
inspect the per-LRU results before RUN.

The control API accepts `FREEZE`/`FRZ`, `RUN`, `DSTORE`, and `RESTORE` as
well as lowercase names. From the command line:

```sh
sim --base-port 6900 frz
sim --base-port 6900 dstore before-ipl
sim --base-port 6900 resume
sim --base-port 6900 freeze --at 30
sim --base-port 6900 dstores
sim --base-port 6900 restore before-ipl
sim --base-port 6900 rename-dstore before-ipl baseline
```

`resume` sends RUN; the existing CLI `run` command still launches a
configuration. `inspect` includes the simulation clock, store list, and
per-component transaction results. Starting a command acknowledges its
acceptance; the transaction reports its eventual result.

#### LRU state adapters

A small LRU can explicitly mark ordinary JSON fields:

```coffee
@markDstore 'config', ['sampleMs', 'gain']
@markDstore 'state', ['count', 'samples', 'fault']
```

The resulting `state.json` has `config` and `state` objects. An optional
third argument identifies the object owning the fields. All marked values
must be JSON data. Mark every field needed to reconstruct that model.

Without explicit marks, the base LRU saves a data graph, preserving typed
storage, memory aliases, maps, sets, register objects, and power state.
This includes GPC CPU/IOP memory and execution state and MMU volume contents.
Host sockets, DOM nodes, reporting machinery, and graphics resources are
recreated by the new launch. Restored model references reconnect to those
resources; saved continuations call methods on the restored objects. A complex LRU can override
`saveDstore(directory)`, `validateDstore(directory)`, and
`restoreDstore(directory)`; these may return promises and may organize
additional files within that directory. Validation must not change state.
Optional `beforeRestoreDstore()` and `afterRestoreDstore()` hooks release and
rebuild native resources around restoration (for example GPC barrier
membership and MDU GPU buffers).

Simulation work must use the timers and `now()` exported by
`com/simRuntime.coffee`, including their corresponding clear functions. Schedule
persistent work as a named method call, with progress held in model fields:

```coffee
import {call, setTimeout} from 'com/simRuntime.coffee'

@pendingWords = []
@replyTimer = setTimeout(call(@, '_finishReply', busID), 25)
```

`call(target, method, ...args)` also describes pending completion callbacks.
Targets and arguments retain their graph aliases; method implementations
come from the installed simulator, never from executable text in the store.
An anonymous pending timer makes DSTORE fail with an explanation, rather
than producing a checkpoint that cannot resume. Native timers are reserved
for control and host lifecycle work. New bus traffic is held automatically
by `Bus` during freeze.

A class that can appear only after startup should register its prototype
with `registerType(Type)`. If it needs constructor-owned callbacks, supply
a factory as the second argument; that factory must build a detached object
without scheduling work or modifying the live simulation. Renderer bundles
preserve class names for these adapters.

#### GPC memory files and checkpoint size

New GPC checkpoints save main memory as `memory.fcm`, the same headerless,
big-endian halfword image consumed by `AGEHarness.loadFCM()`. AP-101S uses
one 1 MiB image. AP-101B concatenates the CPU's 40K fullwords and IOP's 24K
fullwords in address order, for a 256 KiB image. Checkpoint restore copies
backing storage directly so loading the image does not clear access history
or change protection bits.

Companion files hold state FCM does not represent:

- `cpu-protection.bin` (and `iop-protection.bin` for AP-101B): one protection
  bit per halfword, lowest addressed halfword in each byte's low bit.
- `cpu-lastRead.bin.gz`, `cpu-lastWritten.bin.gz`, `cpu-protLastWritten.bin.gz`
  (and their AP-101B IOP counterparts): gzip-compressed backing bytes of the simulator's
  Uint32 tracking arrays, preserving the simulation step of each halfword's
  last read, write, or protection change for debugger highlighting. Each
  AP-101S array is 2 MiB before compression: 524,288 halfwords times four bytes
  per step index, compared with two bytes per halfword in FCM. Compression is
  lossless; memory FCM and packed protection files remain uncompressed.
  Older checkpoints with raw `.bin` tracking files still restore normally.
  Compressed files are decompressed and validated before model state changes.
- `state.json`: model state, registers, execution state, and graph references
  to the binary storage.
- `runtime.json`: clocks, timers, queued operations, and the process's model
  graph. It currently repeats the model metadata to preserve aliases between
  pending calls and model objects. It references the same binary files;
  memory and tracking arrays are not written twice.

Keep both JSON files and the binary files together: the current restore
path reads and validates both JSON files. Newly written JSON uses two-space
indentation and a trailing newline for readability. The remaining duplication can be
removed by writing one graph containing the model and pending work, or by
using shared node references between the model and runtime files.
An embedded process's runtime graph also includes its other actors, so its
runtime file can be larger than the individual LRU's state file.

Binary-backed graphs use graph version 3, within the existing version 2
checkpoint manifest/runtime protocol. The reader still accepts older
JSON-only version 2 graphs. Missing or incorrectly sized binary files fail
validation before live model state changes. Newly saved GPC checkpoints
require a build with this binary-storage support.

For the live GPC1 tested before enabling JSON indentation and tracking compression, the two JSON files totaled
61,933,101 bytes before this change. The complete new GPC directory totaled
8,890,969 bytes (about 86% smaller), including a 1,048,576-byte FCM and all
protection and access-history data. The remaining two JSON files totaled
1,485,401 bytes.

#### Restart-portable checkpoints

Version 2 stores contain the simulation clocks (including bus microsecond
stamps), pending timers, queued bus deliveries, partial transfers, and model
state. No continuation cache or original process heap is needed. GPC run
loops resume their saved execution progress; MMU media, MDM/PCMMU partial
transactions, signal generators, and MDU screens and timers survive restart.
UDP sockets and shared-memory rings are newly opened; their saved pending
traffic replays once after RUN. Restoring remains cooperative, with each
process held at an event-loop boundary.

To restart from a store:

1. Start the manager and the same configured LRU processes with the same
   simulator build and model configuration. The store directory can be
   copied to the new configuration's datastore root.
2. FRZ, select the named store, then RESTORE. The manager validates all
   members before applying their state and restores its session clock.
3. Check the per-LRU completion results, then RUN.

The manager itself may be restarted; it discovers stores from their
manifests. Version 1 runtime stores are incompatible: save a new version 2
store before relying on restart recovery. Restoring does not recreate a
process launch or reopen external debugger clients; launch the configured
processes first. Custom LRU adapters must reconstruct their own external
resources and describe their pending work using the runtime API.

`com/dstore` tests save in one Node process and restore in another, including
running GPCs, partial transactions, and queued UDP/SHM traffic after deleting
the original shared-memory segment. `sim/control` tests restart the manager
and configured service processes before restore. To exercise real MDU
windows too, build `electron` and run `node test/meds/_checkpoint.cjs`; it
restarts Electron, restores every screen, and checks a saved display timer.
