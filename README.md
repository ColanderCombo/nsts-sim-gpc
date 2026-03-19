
nsts-sim-gpc - Space Shuttle AP-101 Simulator
---------------------------------------------

This repository implements an instruction level simulator for the 
IBM 4Pi AP-101 computer, specifically the B & S models used as the
Space Shuttle Flight Computers.

Two entry points are provided: a batch mode that executes the provided
code and emits a trace (GPC-BATCH.sh), and a interactive debugger gui
that provides a number of useful tools for single stepping, breakpoints
and data display (GPC-DEBUG.sh)

While this tree includes a simple assembler and (very) simple linker, 
the nsts-sdl-dps repository provides wrappers to create a AP-101 toolchain
and a cmake based build system that is the preferred way to use the gpc-sim.

nsts-sdl-dps provides:
    - gpc-batch and gpc-debug wrappers
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

The simulator is a nodejs/electron app, and requires at least node and npm be installed before use. Then SETUP.sh can be used to run all the necessary package installation and
build steps:

```
cd nsts-sim-gpc
./SETUP.sh
```

This installs electron and all the other required npm packages, so it might take a while.

If you use the simulator via the sdl build system, it will take care of all of this for you.

Usage
-----

We provide commands to generate an execution trace in batch mode, dump an image disassembly
similar to the IBM 'DASS' utility, and an interactive debugger.  All the commands take a '.fcm' file as input

  - GPC-BATCH.sh <fcm>
    - ```
Usage: gpc-batch [options] <fcm-file>

GPC Batch Simulator — run AP-101 programs

Arguments:
  fcm-file             FCM memory image to load

Options:
  --start <addr>       start address in hex
  --max-steps <n>      max instructions to execute (default: "100000")
  --break <addr>       stop at halfword address (hex)
  --output <file>      write trace to file instead of stdout
  --dump-interval <n>  register dump every N steps (default: 100) (default: "100")
  --symbols <file>     load symbol table JSON from linker
  --trace              enable instruction trace (default) (default: true)
  --no-trace           disable instruction trace
  --interactive        interactive terminal I/O
  --ebcdic             use EBCDIC encoding for character I/O
  --trap-svc-error     intercept HAL/S SEND ERROR SVCs (default) (default: true)
  --no-trap-svc-error  pass SEND ERROR SVCs to SVC handler
  --disasm [end]       disassemble from start to END (hex)
  --infile0 <file>     read input for channel 0
  --infile1 <file>     read input for channel 1
  --infile2 <file>     read input for channel 2
  --infile3 <file>     read input for channel 3
  --outfile0 <file>    write output for channel 0
  --outfile1 <file>    write output for channel 1
  --outfile2 <file>    write output for channel 2
  --outfile3 <file>    write output for channel 3
  --outfile4 <file>    write output for channel 4
  --outfile5 <file>    write output for channel 5
  --outfile6 <file>    write output for channel 6
  --outfile7 <file>    write output for channel 7
  -h, --help           display help for command
  ```

  - GPC-DUMP.sh <fcm>
    - ```
Usage: gpc-dump [options] <fcm-file>

FCM Dumper — disassemble and inspect FCM memory images

Arguments:
  fcm-file          FCM memory image to inspect

Options:
  --symbols <file>  symbol JSON file (default: <fcm>.sym.json)
  --no-symbols      allow running without symbol file
  --output <file>   write output to file instead of stdout
  --columns <n>     columns in symbol table grid (default: "7")
  --asm             enhanced disassembly: Rx registers, @ for indirect, # for indexed
  -h, --help        display help for command
```

  - GPC-DEBUG.sh
    - ![GPC debugger window screenshot](doc/gpcDebuggerWindow.png)

Repository Contents
-------------------

The gpc simulator was originally part of a larger system that also simulates other avionics.  The gpc has been extracted, but things are a bit more complicated than they could be;

  - `simRunner/` contains the electron main & render process implementation. It uses files from `config/` to load and initialize simulated line replacable units (LRU's).  We're only using electron for the interactive debugger and have hijacked the simRunner to directly load the GPC lru+debugger

  - `com/` contains common utilies, including a simple 'Bus' that lets LRUs communicate via multicast UDP packets.  In the gpc it's used to emulate the physical Shuttle busses connected to the IOP.

  - `cde/` contains definitions of Lit gui elements ([https://lit.dev/]), including the toplevel `<cde-window>` that styles the window to the CDE look and feel.  There's no
  compelling reason to have this, other than CDE shows up quite a bit in Shuttle documentation from the 1990's and 2000's--and I think it looks neat.

  - `esbuild/` contains build system files.

  - `gpc/` contains the simulated AP-101 definition
    - `gpc/data` contains some simple input to the simlator tools.  These are old.  Prefer files in the `sdl` repository
    - `gpc/dev` contains scratch and files not currently used.
    - `gpc/gen` contains a couple of `.fcm` files usable for testing.  again, prefer files from `sdl`
    - `gpc/gui` contains the definitions of the gui elements used to build the debugger.
    - `ap101.coffee` is the definition of the GPC LRU, used here by the debugger
    - `cpu_*.coffee` contains the implementation of the CPU half of the AP-101
    - `iop_*.coffee` contains the implementation of the IOP half of the AP-101
      - `iop_msc_*.coffee` is for the IOP Master Sequence Controller (MSC)
      - `iop_bce_*.coffee` is for the many IOP Bus Control Elements (BCE)
    - the `cpu_*` and `iop_*` files split out the actual instruction definitions in the `_instr.coffee` files.
    - `mcm.coffee` implements the Modular Core Memory (a.k.a. the RAM)
    - `regmem.coffee` implements the registers and PSW 
    - `run_*.coffee` implement the cli tools.
    - `halUCP.coffee` implements basic (IBM style) file I/O expected by the HAL/S runtime when running in the mainframe based SDL environment.  Useful for testing, not avaiable in the flight configuration. (Named after the S/360 'HAL/S User Control Program' simulator)
    - `ebcdic.coffee`, `floatIBM.coffee`, `symbolTable.coffee` and `util.coffee` are all utilities used by other parts of the simulator

Development Notes
-----------------

  - The GPC simulator (and larger sim environment it's pulled from) was written over a long period of time and exhibits some strange patterns because of it.  The nodejs/electron/coffee setup allowed very fast iteration.  Today, starting from scratch, I would not choose the same environment.
  
  - electron was a very fast way to iterate on graphical tools for debugging (and WebGL based displays for e.g., MEDS). While it's still pretty good for that, changes in
  how it handles the separation between the main and rendering process have made it much less convenient to work with. 
  
  - coffeescript is a terse, easy to read alternative to base javascript.  Unfortunately, it's been largely abandoned for years.  I've had to convert some files to typescript and even experimented with civet--a coffeescript like dialect for typescript. Future work will likely be in typescript.

  - A rewrite of the AP-101 simulator in C using the SIMH framework is in progress

AP-101 Implementation Notes
---------------------------

  - This implementation is at an *instruction* level and makes no attempt to simulate timing, microcode, or internal state.

  - The implementation is very verbose.  I've copied blocks of the POO directly into the comments and used it to guide the implementaton.  Instruction opcode patterns and decoding is defined using bit strings (like '00011xxx11100yyy'), and additional format information is attached to make disassembly easier.  The intent is to make it as simple as we can to understand what the processor is doing and locate any errors in our logic.  Once verified, converting this to a much terser decoding process would make sense.

  - Implementation initially targeted the AP-101/B model originally installed in the Shuttle. The current version includes instructions and some features from the AP-101/S upgrade.  I have not made a complete pass through the POO and implementation to verify these changes.

  - The simulator includes an implementation of the IOP coprocessor used to interface to the 24 serial shuttle busses. This implementation has only had *very* basic testing and almost certainly will not work with real MSC/BCE programs.  This is future work.

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

