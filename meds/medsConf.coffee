
# The IDP -> MDU messages.  Word 0 is the tag; the tags are 0xFF00 and up so
# they cannot collide with a format control word
#
export MDUMsg = {
  FILL:      0xff00     # a display-memory fill: DEU address, then the words
  RESET_SPL: 0xff02     # the GPC reset the scratch pad line
  CLOCK:     0xff03     # the header clock
  POLL:      0xff04     # a GPC polled this unit
  HEARTBEAT: 0xffff     # the IDP is alive
}

export MDUMsgName = {}
MDUMsgName[v] = k for k, v of MDUMsg

export MEDSConf = {
  mdus: {
    CRT1: {
      lruID: 0x02
      busses: ['_IDP1']
      dataBus: {P:"IDP1", S:null}
      powerBus: ["AB1", "MNA"]
      lightDimBus: "L/C"
      busAddr: 0x16
    }
    CRT2: {
      lruID: 0x02
      busses: ['_IDP2']
      dataBus: {P:"IDP2", S:null}
      powerBus: ["BC2", "MNB"]
      lightDimBus: "L/C"
      busAddr: 0x07
    }
    CRT3: {
      lruID: 0x02
      busses: ['_IDP3']
      dataBus: {P:"IDP3", S:null}
      powerBus: ["CA1", "MNC"]
      lightDimBus: "L/C"
      busAddr: 0x15
    }
    CRT4: {
      lruID: 0x02
      busses: ['_IDP4']
      dataBus: {P:"IDP4", S:null}
      powerBus: ["CA2", "MNC"]
      lightDimBus: "MS"
      busAddr: 0x19
    }
    CDR1: {
      lruID: 0x03
      busses: ['_IDP3','_IDP1']
      dataBus: {P:"IDP3", S:"IDP1"}
      powerBus: ["MNC"]
      lightDimBus: "L/C"
      busAddr: 0x1A
    }
    CDR2: {
      lruID: 0x04
      busses: ['_IDP1','_IDP2']
      dataBus: {P:"IDP1", S:"IDP2"}
      powerBus: ["MNB"]
      lightDimBus: "L/C"
      busAddr: 0x0B
    }
    PLT1: {
      lruID: 0x05
      busses: ['_IDP2','_IDP1']
      dataBus: {P:"IDP2", S:"IDP1"}
      powerBus: ["MNA"]
      lightDimBus: "RT"
      busAddr: 0x1C
    }
    PLT2: {
      lruID: 0x06
      busses: ['_IDP3','_IDP2']
      dataBus: {P:"IDP3", S:"IDP2"}
      powerBus: ["MNC"]
      lightDimBus: "RT"
      busAddr: 0x0D
    }
    MFD1: {
      lruID: 0x07
      busses: ['_IDP2','_IDP3']
      dataBus: {P:"IDP2", S:"IDP3"}
      powerBus: ["MNB"]
      lightDimBus: "L/C"
      busAddr: 0x0E
    }
    MFD2: {
      busses: ['_IDP1','_IDP3']
      lruID: 0x08
      dataBus: {P:"IDP1", S:"IDP3"}
      powerBus: ["MNA"]
      lightDimBus: "L/C"
      busAddr: 0x13
    }
    AFD1: {
      lruID: 0x09
      busses: ['_IDP4','_IDP2']
      dataBus: {P:"IDP4", S:"IDP2"}
      powerBus: ["MNC"]
      lightDimBus: "MS"
      busAddr: 0x10
    }
  }
  idps: {
    IDP1: {
      lruID: 0x00
      busses: ['_IDP1', 'FC1', 'FC2', 'FC3', 'FC4', 'DK1','_KYBD1']
      powerBus: ["AB1","MNA"]
      fcBus: ["FC1","FC2","FC3","FC4"]
      dkBus: "DK1"
      errorMsgTarget: ["CRT1","CDR1","CDR2","MFD2","PLT1"]
      busAddr: 0x01
    }
    IDP2: {
      lruID: 0x00
      busses: ['_IDP2', 'FC1', 'FC2', 'FC3', 'FC4', 'DK2','_KYBD2','_KYBD3']
      powerBus: ["CA1","MNC"]
      fcBus: ["FC1","FC2","FC3","FC4"]
      dkBus: "DK2"
      errorMsgTarget: ["CRT2","PLT2","PLT1","MFD1","CDR2","AFD1"]
      busAddr: 0x02
    }
    IDP3: {
      lruID: 0x00
      busses: ['_IDP3', 'FC1', 'FC2', 'FC3', 'FC4', 'DK3','_KYBD1','_KYBD2']
      powerBus: ["BC2","MNB"]
      fcBus: ["FC1","FC2","FC3","FC4"]
      dkBus: "DK3"
      errorMsgTarget: ["CRT3","PLT2","MFD2","MFD1","CDR1"]
      busAddr: 0x04
    }
    IDP4: {
      lruID: 0x00
      busses: ['_IDP4', 'FC1', 'FC2', 'FC3', 'FC4', 'DK4','_KYBD3']
      powerBus: ["CA2","MNC"]
      fcBus: ["FC1","FC2","FC3","FC4"]
      dkBus: "DK4"
      errorMsgTarget: ["CRT4","AFD1"]
      busAddr: 0x08
    }
  }
  adcs: {
    ADC1A: {
      lruID: 0x0A
      busses: ['_IDP1', '_IDP2']
      powerBus: ["MNA"]
      dataBus: ["IDP1","IDP2"]
      dataIn: ["MPS","OMS","SPI"]
      busAddr: 0x18
    }
    ADC1B: {
      lruID: 0x0A
      busses: ['_IDP3', '_IDP4']
      powerBus: ["MNB"]
      dataBus: ["IDP3","IDP4"]
      dataIn: ["MPS","OMS","SPI"]
      busAddr: 0x12
    }
    ADC2A: {
      lruID: 0x0B
      busses: ['_IDP1', '_IDP2']
      powerBus: ["MNA"]
      dataBus: ["IDP1","IDP2"]
      dataIn: ["HYD","APU"]
      busAddr: 0x14
    }
    ADC2B: {
      lruID: 0x0B
      busses: ['_IDP3', '_IDP4']
      powerBus: ["MNB"]
      dataBus: ["IDP3","IDP4"]
      dataIn: ["HYD","APU"]
      busAddr: 0x11
    }
  }
}