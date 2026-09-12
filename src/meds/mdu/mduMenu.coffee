
export default Menus = {
  MAIN: {
    id: 0x01
    title: " MAIN MENU   "
    0: { keyTitle: "" }
    1: { keyTitle: "FLT \nINST", link: "FLT_INST" }
    2: { keyTitle: "SUBSYS \nSTATUS ", link: "SUBSYS" }
    3: { keyTitle: "DPS" , link: "DPS", }
    4: { keyTitle: "MEDS \nMAINT", link: "MAINT" }
    5: { keyTitle: "VIDEO" }
  }
  FLT_INST: {
    id: 0x02
    title: "FLIGHT INSTRUMENT MENU "
    0: { keyTitle: "UP", link: 'MAIN'}
    1: { keyTitle: " A/E\n PFD",  action: (t) -> t.setCurrentDisplay("AE_PFD",1) }
    2: { keyTitle: " ORBIT\n PFD", action: (t) -> t.setCurrentDisplay("ORBIT_PFD",2) }
    3: { keyTitle: "DATA\n BUS", link: 'DATA_BUS' }
    4: { keyTitle: " MEDS\nMSG RST" }
    5: { keyTitle: " MEDS \n MSG ACK" }
  }
  # menu id 0x03-0x05 --SPARE--
  AE_FLT_INST: {
    title: "ASCENT/ENTRY FLIGHT INSTRUMENT MENU "
    0: { keyTitle: "UP", link: 'MAIN'}
    1: { keyTitle: "ADI/\nAVVI",  action: (t) -> t.setCurrentDisplay("AE_PFD",1) }
    2: { keyTitle: "HST/\nAMI", action: (t) -> t.setCurrentDisplay("ORBIT_PFD",2) }
    3: { keyTitle: "COMP\nADI/HST", action: (t) -> t.setCurrentDisplay("AE_PFD",3) }
    4: { keyTitle: "DATA\n BUS", link: 'DATA_BUS' }
    5: { keyTitle: " MEDS\n MSG ACT" }
  }
  DATA_BUS: {
    id: 0x06
    title: "DATA BUS SELECT MENU"
    # highlight tracks the FC bus actually selected (edgekey n = FC bus n)
    activeItem: (t) -> t.flightCritBus
    0: { keyTitle: "UP", link: 'FLT_INST' }
    1: { keyTitle: "FC BUS\n1", action: (t) -> t.setFCBus(1) }
    2: { keyTitle: "FC BUS\n2", action: (t) -> t.setFCBus(2) }
    3: { keyTitle: "FC BUS\n3", action: (t) -> t.setFCBus(3) }
    4: { keyTitle: "FC BUS\n4", action: (t) -> t.setFCBus(4) }
    5: { keyTitle: "" }
  }
  SUBSYS: {
    id: 0x07
    title: "SUBSYSTEM MENU   "
    0: { keyTitle: "UP", link: 'MAIN' }
    1: { keyTitle: "OMS/ \nMPS", action: (t) -> t.setCurrentDisplay("OMS_MPS", 1) }
    2: { keyTitle: "HYD/ \nAPU", action: (t) -> t.setCurrentDisplay("HYD_APU", 2) }
    3: { keyTitle: "SPI",        action: (t) -> t.setCurrentDisplay("SPI", 3) }
    4: { keyTitle: "PORT\nSELECT",action: (t) -> t.toggleCmdPort() }
    5: { keyTitle: " MEDS \n MSG ACK" }
  }
  DPS: {
    id: 0x08
    title: "DPS MENU       "
    action: (t) -> t.setCurrentDisplay("DPS")
    0: { keyTitle: "UP", link: 'MAIN'}
    1: { keyTitle: "" }
    2: { keyTitle: "" }
    3: { keyTitle: "" }
    4: { keyTitle: "MEDS\nMSG RST" }
    5: { keyTitle: "MEDS\nMSG ACK" }
  }
  VIDEO: {
    id: 0x09
    title: "VIDEO MENU"
    0: { keyTitle: "UP", link: 'MAIN'}
  }
  MAINT: {
    id: 0x0C
    title: "MAINTENANCE MENU"
    action: (t) -> t.setCurrentDisplay("MAINT")
    0: { keyTitle: "UP", link: "MAIN" }
    1: { keyTitle: "FAULT\nSUMM", link: "FAULT_SUMM" }
    2: { keyTitle: "CONFIG\nSTATUS", link: "CONFIG_STATUS"}
    3: { keyTitle: "CST", link: "CST"}
    4: { keyTitle: "MEMORY\nMGMT", link: 'MEM_MGMT'}
    5: { keyTitle: "" }
  }
  FAULT_SUMM: {
    id: 0x0A
    title: "FAULT SUMMARY   "
    action: (t) -> t.setCurrentDisplay("FAULT_SUMM")
    0: { keyTitle: "UP", link: 'MAINT' }
    1: { keyTitle: "" }
    2: { keyTitle: "" }
    3: { keyTitle: "CLEAR\nMSGS " }
    4: { keyTitle: "MEDS\nMSG RST" }
    5: { keyTitle: " MEDS\n MSG ACK" }
  }
  CONFIG_STATUS: {
    #
    # USA-007587/p.253
    #
    # The configuration status submenu allows the viewer to port select to
    # the alternate IDP, USA007587 Rev. A change its reconfiguration mode to
    # either AUTO or MAN, or change the viewing mode. The viewing mode can
    # be changed only for the Hosiden MDUs (all flight MDUs are Hosiden).
    # The negative viewing mode enhances the read- ability of the aft MDUs.
    # When negative viewing is selected, “NEG VIEW” is displayed above the
    # flight-critical bus selection and reconfiguration mode on the MEDS
    # status area of the MDU.
    #
    id: 0x0D
    title: "MDU CONFIGURATION MENU"
    0: { keyTitle: "UP", link: 'MAINT' }
    1: { keyTitle: "PORT\nSELECT", action: (t) -> t.toggleCmdPort() }
    2: { keyTitle: "AUTO/\nMANUAL", action: (t) -> t.toggleReconfigMode() }
    3: { keyTitle: "" }
    4: { keyTitle: "" }
    5: { keyTitle: "CHANGE\nVIEW", action: (t) -> t.toggleNegView() }
  }
  CST: {
    id: 0x0E
    title: "CST MENU SELECTION"
    0: { keyTitle: "UP", link: 'MAINT' }
    1: { keyTitle: "START\nMDU", action: (t) -> t.seq_mdu_selftest() }
    2: { keyTitle: "START\nIDP", link: 'INTER_CST'}
    3: { keyTitle: "START\nADC1X" }
    4: { keyTitle: "START\nADC2X" }
    5: { keyTitle: "" }
  }
  INTER_CST: {
    id: 0x0B
    title: "INTERACTIVE CST"
    action: (t) -> t.setCurrentDisplay("IDP_CST")
    0: { keyTitle: "UP", link: 'CST' }
    1: { keyTitle: "" }
    2: { keyTitle: "" }
    3: { keyTitle: "" }
    4: { keyTitle: "" }
    5: { keyTitle: "HW\nCST" }
  }
  MEM_MGMT: {
    id: 0x0F
    title: "MEMORY MANAGEMENT SELECTION"
    0: { keyTitle: "UP", link: 'MAINT' }
    1: { keyTitle: "IDP", link: 'MEM_IDP'}
    2: { keyTitle: "MDU", link: 'MEM_MDU'}
    3: { keyTitle: "ADCXX", link: 'MEM_ADC'}
    4: { keyTitle: "ADCXX", link: 'MEM_ADC'}
    5: { keyTitle: "FILE\nPATCH", link: 'FILE_PATCH'}
  }
  MEM_IDP: {
    id: 0x10
    title: "XXXXX MEMORY MANAGEMENT SELECTION"
    0: { keyTitle: "UP", link: 'MEM_MGMT' }
    1: { keyTitle: "DUMP\nRAM" }
    2: { keyTitle: "DUMP\nEEPROM" }
    3: { keyTitle: "PROG\nLOAD", link: 'PROG_LOAD_IDP'}
    4: { keyTitle: "" }
    5: { keyTitle: "" }
  }
  MEM_MDU: {
    id: 0x10
    title: "XXXXX MEMORY MANAGEMENT SELECTION"
    0: { keyTitle: "UP", link: 'MEM_MGMT' }
    1: { keyTitle: "DUMP\nRAM" }
    2: { keyTitle: "DUMP\nEEPROM" }
    3: { keyTitle: "PROG\nLOAD", link: 'PROG_LOAD_MDU' }
    4: { keyTitle: "" }
    5: { keyTitle: "" }
  }
  MEM_ADC: {
    id: 0x10
    title: "XXXXX MEMORY MANAGEMENT SELECTION"
    0: { keyTitle: "UP", link: 'MEM_MGMT' }
    1: { keyTitle: "DUMP\nRAM" }
    2: { keyTitle: "" }
    3: { keyTitle: "" }
    4: { keyTitle: "" }
    5: { keyTitle: "" }
  }
  PROG_LOAD_IDP: {
    id: 0x11
    title: "XXXX MEMORY LOADING"
    0: { keyTitle: "UP", link: 'MEM_IDP' }
    1: { keyTitle: "PREV\nPROG" }
    2: { keyTitle: "NEXT\nPROG" }
    3: { keyTitle: "LOAD\nRAM" }
    4: { keyTitle: "LOAD\nRAM/EE" }
    5: { keyTitle: "SET\nCURNT" }
  }
  PROG_LOAD_MDU: {
    title: "XXXX MEMORY LOADING"
    0: { keyTitle: "UP", link: 'MEM_IDP' }
    1: { keyTitle: "PREV\nPROG" }
    2: { keyTitle: "NEXT\nPROG" }
    3: { keyTitle: "" }
    4: { keyTitle: "LOAD\nRAM/EE" }
    5: { keyTitle: "" }
  }

  FILE_PATCH: {
    id: 0x12
    title: "FILE PATCHING SELECTION"
    action: (t) -> t.curDisplay = "FILE_PATCH"
    0: { keyTitle: "UP", link: 'MAINT' }
    1: { keyTitle: "PREV\nFILE" }
    2: { keyTitle: "NEXT\nFILE" }
    3: { keyTitle: "SELECT", link: 'FILE_PATCH'}
    4: { keyTitle: "" }
    5: { keyTitle: "" }
  }
  DO_FILE_PATCH: {
    id: 0x13
    title: "XXXXXXXX XXX FILE PATCHING"
    0: { keyTitle: "UP", link: 'MAIN' }
    1: { keyTitle: "" }
    2: { keyTitle: "" }
    3: { keyTitle: "" }
    4: { keyTitle: "" }
    5: { keyTitle: "" }
  }
  DISCONNECTED: {
    title: ""
    0: { keyTitle: "AUTO\nCONFIG" }
    1: { keyTitle: "PRI\nMANUAL" }
    2: { keyTitle: "SEC\nMANUAL" }
    3: { keyTitle: "" }
    4: { keyTitle: "" }
    5: { keyTitle: "" }
  }
}
