
gpcErrorCodes = {
    # JSC-18819/p.251
    #
    0x04: {nom: "DMA store protect violation"}
    0x06: {nom: "AGE (ground test interface)"}
    0x08: {nom: "DMA fetch timeout"}
    0x09: {nom: "DMA queue overflow"}
    0x20: {nom: "Spare (Bad EX3 INTRUPT)"}
    0x2f: {nom: "GPC power transient"}
    0x30: {nom: "Spare (Bad EX4 INTRUPT"}
    0x41: {nom: "Illegal engage/TERM B combo"}
    0x43: {nom: "Data bus MIA XMIT-ENA register disagree"}
    0x44: {nom: "String(s) downmoded: two listen errors"}
    0x45: {nom: "String(s) downmoded: RS data check"}
    0x46: {nom: "String(s) downmoded: bypass miscompare"}
    0x47: {nom: "String downmoded: last remaining string"}
    0x82: {nom: "DMA multibit err (IOP)"}
    0x83: {nom: "CPU multibit err (CPU)"}
    0x85: {nom: "CPU ROS microstore parity"}
    0x86: {nom: "Interrupt page fault"}
    0x87: {nom: "'ENDOP' timeout"}
    0x88: {nom: "EA fault (effective addressing)"}
    0x89: {nom: "CPU cannot continue"}
    0x90: {nom: "Illegal CPU instruction of PCI/PCO cmd"}
    0x91: {nom: "Privileged instruction violation"}
    0x94: {nom: "Masked (FX/POINT overflow)"}
    0x95: {nom: "Masked (FL/POINT significance)"}
    0x97: {nom: "CPU store-protect violation"}
    0x99: {nom: "Masked (exponent underflow)"}
    0x9a: {nom: "Exponent overflow during convert"}
    0x9b: {nom: "Floating-point exponent overflow"}
    0x9c: {nom: "Floating-point invalid divide by zero"}
    0xb0: {nom: "Bad SVC (udefined SVC type)"}
    0xb1: {nom: "Invalid inputs to HAL subroutine"}
    0xb2: {nom: "'RESTART' SVC requested (software runaway)"}
    0xb3: {nom: "CRT 'Display Error Handler' Invoked"}
    0xc0: {nom: "Max rate job overload"}
    0xc1: {nom: "Alt rate job overload (initiate RESTART)"}
    0xc2: {nom: "Alt rate job overload (minor cycle extend)"}
    0xe0: {nom: "Requested 'instruction' not store protected"}
    0xf0: {nom: "Watchdog timeout (I-fail illuminated)"}
    0xf1: {nom: "IOP 'FAIL' latch (I-fail illuminated)"}
    0xf2: {nom: "IOP control monitor idle (NON-START UP)"}
    0xf3: {nom: "IOP ROS parity"}
    0xf4: {nom: "IOP timing fault (oscillator failure)"}
}