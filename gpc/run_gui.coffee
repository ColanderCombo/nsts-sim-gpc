fs = require 'fs'
path = require 'path'
import {AP101} from 'gpc/ap101'
import React from 'react'
import 'cde/cde-window'
import 'cde/toolbar'
import 'cde/bit-field'
import 'cde/split-pane'
import 'gpc/gui/gpc-register'
import 'gpc/gui/gpc-breakpoints'
import 'gpc/gui/gpc-disasm'
import 'gpc/gui/gpc-instr'
import 'gpc/gui/gpc-regview'
import 'gpc/gui/gpc-watch'
import 'gpc/gui/gpc-memory'
import 'gpc/gui/gpc-sections'
import 'gpc/gui/gpc-terminal'


export class DebugGUI extends AP101
  constructor: (CONFIG) ->
    super(CONFIG)
    @ipcRenderer = require('electron').ipcRenderer
    if not @ipcRenderer
      throw new Error("DebugGUI: require('electron').ipcRenderer failed!")


  _terminal: () -> document.querySelector('gpc-terminal')
  _breakpointList: () -> document.querySelector('gpc-breakpoints')
  _disasm: () -> document.querySelector('gpc-disasm')
  _instruction: () -> document.querySelector('gpc-instr')
  _registers: () -> document.querySelector('gpc-regview')
  _watch: () -> document.querySelector('gpc-watch')
  _memory: () -> document.querySelector('gpc-memory')
  _sections: () -> document.querySelector('gpc-sections')

  start: () ->
    console.log("DebugGUI Start")
    console.log("DebugGUI CONFIG:", JSON.stringify(@CONFIG, null, 2))

    # Get FCM/symbols from config or use defaults
    # Note: @CONFIG is already the gpc1 LRU config (passed from startup.civet)
    lruConf = @CONFIG.config or {}
    fcmFile = lruConf.fcmFile
    symbolsFile = lruConf.symbolsFile
    entryPoint = lruConf.entryPoint  # optional override

    console.log("DebugGUI fcmFile:", fcmFile)
    console.log("DebugGUI symbolsFile:", symbolsFile)

    if fcmFile
      # Resolve path: absolute paths used as-is, relative resolved from NSTS_TOP
      fcmPath = if path.isAbsolute(fcmFile) then fcmFile else path.join(@CONFIG.NSTS_TOP, fcmFile)
      # Store initial load parameters for reset
      @initialFcmPath = fcmPath
      @initialSymbolsPath = symbolsFile
      @initialEntryPoint = entryPoint
      @loadFCMFile(fcmPath, symbolsFile, entryPoint)
    else
      # Fallback to hardcoded default
      @initialFcmPath = null
      @loadMemFile('SIMPLE.fcm', 0x005f)

    # Wire HAL/S I/O trap callbacks to <gpc-terminal> component
    @halUCP.outputCallback = (text) => @_terminal()?.appendText(text)
    @halUCP.inputCallback = () =>
      @_terminal()?.activateInput()
      @updateDisplay()
    # Wire SVC error callback to terminal
    @halUCP.errorCallback = (msg) =>
      @_terminal()?.appendText("\n*** #{msg}\n\n")
      process.stderr.write "\n" + msg + "\n\n"

    # Listen for input submitted from <gpc-terminal>
    document.addEventListener 'terminal-input', (e) =>
      text = e.detail.text
      wasRunning = @halUCP.wasRunning
      @halUCP.provideInput(text)
      @halUCP.wasRunning = false
      @updateDisplay()
      if wasRunning and not @breakOnInput
        @run()

    # Listen for break-on-input toggle from <gpc-terminal>
    document.addEventListener 'break-on-input-changed', (e) =>
      @breakOnInput = e.detail.value

    # Listen for breakpoint events from <gpc-disasm>
    document.addEventListener 'breakpoint-toggle', (e) =>
      @toggleBreakpoint(e.detail.addr)
    document.addEventListener 'breakpoint-menu', (e) =>
      @showBreakpointMenu({ clientX: e.detail.x, clientY: e.detail.y }, e.detail.addr)

    # Listen for section selection from <gpc-sections>
    document.addEventListener 'section-selected', (e) =>
      @selectedSection = e.detail.name
      @_memory()?.selectedSection = @selectedSection
      @updateDisplay()

    # Listen for watch selection
    document.addEventListener 'watch-selected', (e) =>
      @selectedWatch = e.detail.name
      @watchAddresses = e.detail.addresses
      @updateDisplay()

    @setupKeyboard()
    # Poll until React has committed the DOM, then wire components
    waitForDom = () =>
      disasmEl = @_disasm()
      memEl = @_memory()
      sectEl = @_sections()
      process.stderr.write "waitForDom: disasm=#{!!disasmEl}, mem=#{!!memEl}, sect=#{!!sectEl}\n"
      if disasmEl and memEl and sectEl
        # Wire disasm
        disasmEl.cpu = @cpu
        disasmEl.sym = @sym
        disasmEl.halUCP = @halUCP
        disasmEl.breakpoints = @breakpoints
        # Wire memory
        memEl.cpu = @cpu
        memEl.sym = @sym
        memEl.selectedSection = @selectedSection
        memEl.watchAddresses = @watchAddresses
        # Wire sections
        sectEl.sym = @sym
        sectEl.selectedSection = @selectedSection
        # Wire watch
        watchEl = @_watch()
        if watchEl
          watchEl.cpu = @cpu
          watchEl.sym = @sym
        # Wire breakpoint list
        bpListEl = @_breakpointList()
        if bpListEl
          bpListEl.cpu = @cpu
          bpListEl.breakpoints = @breakpoints
        # Wire instruction decode
        instrEl = @_instruction()
        if instrEl
          instrEl.cpu = @cpu
        # Wire registers
        regsEl = @_registers()
        if regsEl
          regsEl.cpu = @cpu
        # Initial display
        @updateDisplay()
        setTimeout(() =>
          @updateDisplay()
        , 100)
        window.addEventListener('resize', () => @updateDisplay())
      else
        requestAnimationFrame(waitForDom)
    requestAnimationFrame(waitForDom)

  setupKeyboard: () ->
    document.addEventListener 'keydown', (e) =>
      # Don't intercept keys when any input element is focused
      tag = e.target?.tagName?.toLowerCase()
      if tag == 'input' or tag == 'textarea'
        return
      switch e.which
        when 121 # F10
          e.preventDefault()
          @step()
        when 116 # F5
          e.preventDefault()
          @run()
        when 27  # Escape
          e.preventDefault()
          @stop()
        when 120 # F9
          e.preventDefault()
          @reset()
        when 123 # F12
          e.preventDefault()
          @ipcRenderer.send('toggle-devtools')
      switch String.fromCharCode(e.which).toLowerCase()
        when 's'
          if not e.ctrlKey and not e.altKey and not e.metaKey
            if e.target == document.body
              e.preventDefault()
              @step()
        when 'r'
          if not e.ctrlKey and not e.altKey and not e.metaKey
            if e.target == document.body
              e.preventDefault()
              @run()
        when 'p'
          if not e.ctrlKey and not e.altKey and not e.metaKey
            if e.target == document.body
              e.preventDefault()
              @stop()
        when 'f'
          if not e.ctrlKey and not e.altKey and not e.metaKey
            if e.target == document.body
              e.preventDefault()
              @_disasm()?.frameNIA()

  reset: () ->
    super()

    # Clear register change tracking
    @_registers()?.resetTracking()

    # Clear terminal UI
    term = @_terminal()
    if term
      term.clear()
      term.resetInput()

    @updateDisplay()

  quit: () ->
    @ipcRenderer.send('window-close')

  showBreakpointMenu: (e, addr) ->
    # Remove any existing context menu
    old = document.getElementById('gpc-bp-context-menu')
    old?.remove()

    bp = @breakpoints.get(addr)
    menu = document.createElement('div')
    menu.id = 'gpc-bp-context-menu'
    menu.style.cssText = "position: fixed; left: #{e.clientX}px; top: #{e.clientY}px; background: #333; border: 1px solid #666; padding: 2px 0; z-index: 9999; font-family: 'Consolas for Powerline', Consolas, monospace; font-size: 11px; min-width: 140px;"

    makeItem = (label, handler) ->
      item = document.createElement('div')
      item.style.cssText = 'padding: 3px 12px; color: #ccc; cursor: pointer; white-space: nowrap;'
      item.textContent = label
      item.onmouseenter = -> item.style.backgroundColor = '#555'
      item.onmouseleave = -> item.style.backgroundColor = ''
      item.onclick = (ev) ->
        ev.stopPropagation()
        menu.remove()
        handler()
      return item

    addrStr = "0x#{addr.toString(16).padStart(5, '0')}"
    if bp?
      if bp.enabled
        menu.appendChild(makeItem("Disable #{addrStr}", => @disableBreakpoint(addr)))
      else
        menu.appendChild(makeItem("Enable #{addrStr}", => @enableBreakpoint(addr)))
      menu.appendChild(makeItem("Delete #{addrStr}", => @deleteBreakpoint(addr)))
    else
      menu.appendChild(makeItem("Add breakpoint #{addrStr}", => @breakpoints.set(addr, { enabled: true }); @saveBreakpoints(); @updateDisplay()))

    document.body.appendChild(menu)
    # Close on any click elsewhere
    closeHandler = (ev) ->
      if not menu.contains(ev.target)
        menu.remove()
        document.removeEventListener('mousedown', closeHandler, true)
    setTimeout(( -> document.addEventListener('mousedown', closeHandler, true)), 0)

  updateDisplay: () ->
    @_disasm()?.refresh()
    @_registers()?.refresh()
    @_instruction()?.refresh()
    @_watch()?.refresh()
    @_breakpointList()?.refresh()

    # Memory and sections components
    mem = @_memory()
    if mem
      mem.watchAddresses = @watchAddresses
      mem.selectedSection = @selectedSection
      mem.refresh()
    sect = @_sections()
    if sect
      sect.selectedSection = @selectedSection
      sect.refresh()

    @updateToolbar()

  updateToolbar: () ->
    nia = @cpu.psw.getNIA()
    niaEl = document.getElementById('gpc-nia-display')
    if niaEl
      niaEl.textContent = "NIA: #{nia.toString(16).padStart(5, '0')}"
    stepsEl = document.getElementById('gpc-steps-display')
    if stepsEl
      stepsEl.textContent = "Steps: #{@stepCount}"
    statusEl = document.getElementById('gpc-status-display')
    if statusEl
      if @halUCP.waitingForInput
        statusEl.textContent = "INPUT WAIT"
      else if @cpu.psw.getWaitState()
        statusEl.textContent = "WAIT"
      else if @running
        statusEl.textContent = "RUNNING"
      else
        statusEl.textContent = "STOPPED"

  _uiGPCRegister: (id, bits, base, name, slice=-1, sliceend=-1) ->
    <gpc-register id={id} key={id} bits={bits} base={base} name={name} slice={slice} sliceend={sliceend} value={0}/>



  initWindow: () ->
    # All registers (int, float, PSW) are rendered via updateRegisterDisplay()

    mainStyle = {
      display: 'flex'
      flexDirection: 'column'
      height: '100%'
      backgroundColor: '#111'
      color: '#ddd'
      fontFamily: "'Consolas for Powerline', 'Consolas', monospace"
    }

    paneStyle = {
      overflow: 'auto'
      padding: '4px 8px'
    }

    labelStyle = {
      color: '#888'
      fontSize: '10px'
      marginBottom: '2px'
      borderBottom: '1px solid #333'
      paddingBottom: '2px'
    }

    <cde-window title={"GPC Debugger"}>
      <div style={mainStyle}>
        <sim-toolbar style={{padding: '4px 8px', backgroundColor: '#222', borderBottom: '1px solid #444'}}>
          <button onClick={() => this.step()}>Step (F10)</button>
          <button onClick={() => this.run()}>Run (F5)</button>
          <button onClick={() => this.stop()}>Stop (Esc)</button>
          <button onClick={() => this.reset()}>Reset (F9)</button>
          <span id="gpc-status-display" slot="status">STOPPED</span>
          <span id="gpc-steps-display" slot="status">Steps: 0</span>
          <span id="gpc-nia-display" slot="status">NIA: 000e</span>
          <button slot="status" style={{marginLeft: '20px'}} onClick={() => this.quit()}>Quit</button>
        </sim-toolbar>
        <split-pane direction="vertical" initial-size={150} min-size={60} save-key="terminal" style={{flex: '1', overflow: 'hidden'}}>
          <split-pane slot="first" direction="vertical" initial-size={400} min-size={100} save-key="memory">
            <split-pane slot="first" direction="horizontal" initial-size={380} min-size={100} save-key="registers">
              <split-pane slot="first" direction="horizontal" initial-size={220} min-size={80} save-key="watch">
                <gpc-disasm slot="first"></gpc-disasm>
                <div slot="second" style={paneStyle}>
                  <div style={labelStyle}>WATCH</div>
                  <gpc-watch style={{flex: '1'}}></gpc-watch>
                  <div style={Object.assign({}, labelStyle, {marginTop: '4px'})}>BREAKPOINTS</div>
                  <gpc-breakpoints style={{maxHeight: '200px'}}></gpc-breakpoints>
                </div>
              </split-pane>
              <div slot="second" style={paneStyle}>
                <gpc-regview></gpc-regview>
                <div style={Object.assign({}, labelStyle, {marginTop: '4px'})}>INSTRUCTION</div>
                <gpc-instr></gpc-instr>
              </div>
            </split-pane>
            <split-pane slot="second" direction="horizontal" initial-size={100} min-size={60} save-key="sections">
              <gpc-memory slot="first"></gpc-memory>
              <gpc-sections slot="second"></gpc-sections>
            </split-pane>
          </split-pane>
          <gpc-terminal slot="second" id="gpc-terminal"></gpc-terminal>
        </split-pane>
      </div>
    </cde-window>

start = (CONFIG) ->
  gpc = new DebugGUI(CONFIG)
  return gpc

export default { start }
