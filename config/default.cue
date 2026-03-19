start: [
	"idp1",
	"ccms1"
]
enableTouchbar:    false
startSharedWindow: false
lrus: {
	shared: window: {
		width:           600
		height:          800
		x:               10
		y:               10
		backgroundColor: "#444444"
		fullscreen:      false
	}
	ccms1: {
		lru:    "CCMSConsole"
		module: "lps/ccms"
		window: {
			width:           1008
			height:          850
			x:               300
			y:               50
			backgroundColor: "rgb(191,168,158)"
			fullscreen:      false
		}
		config: lru: "CCMS1"
	}
	gpc1: {
		lru:    "GPC"
		module: "gpc/ap101b"
		window: {
			width:           600
			height:          800
			x:               620
			y:               10
			backgroundColor: "#444444"
			fullscreen:      false
		}
		config: lru: "GPC1"
	}
	idp1: {
		shared: true
		lru:    "IDP"
		module: "meds/idp"
		config: lru: "IDP1"
	}
	idp2: {
		shared: true
		lru:    "IDP"
		module: "meds/idp"
		config: lru: "IDP2"
	}
	idp3: {
		shared: true
		lru:    "IDP"
		module: "meds/idp"
		config: lru: "IDP3"
	}
	idp4: {
		shared: true
		lru:    "IDP"
		module: "meds/idp"
		config: lru: "IDP4"
	}
	cdr1: {
		lru: "MDU"
		window: {
			width:      720
			height:     720
			x:          50
			y:          50
			fullscreen: false
			html:       "meds/index.html"
		}
		module:         "meds/mdu"
		enableTouchbar: true
		supersample:    4
		widthThinLine:  0.2
		widthThickLine: 0.15
		config: lru: "CRT1"
		init: {
			menu:    "MAIN"
			display: "AE_PFD"
		}
	}
}
