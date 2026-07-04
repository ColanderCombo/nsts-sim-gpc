fs = require 'fs'
path = require 'path'
import {GUIHarness} from 'gpc/guiharness'
import React from 'react'
import 'cde/cde-window'
import 'cde/toolbar'
import 'cde/bit-field'
import 'cde/split-pane'
import 'cde/dock'
import 'gpc/gui/gpc-register'
import 'gpc/gui/gpc-breakpoints'
import 'gpc/gui/gpc-disasm'
import 'gpc/gui/gpc-instr'
import 'gpc/gui/gpc-regview'
import 'gpc/gui/gpc-watch'
import 'gpc/gui/gpc-memory'
import 'gpc/gui/gpc-sections'
import 'gpc/gui/gpc-labels'
import 'gpc/gui/gpc-terminal'


export class DebugGUI extends GUIHarness
  constructor: (CONFIG) ->
    super(CONFIG)
    @ipcRenderer = require('electron').ipcRenderer
    if not @ipcRenderer
      throw new Error("DebugGUI: require('electron').ipcRenderer failed!")


  # Resolve the LRU config down to an opts object for configureFromOpts.
  # Accepts either the modern `cliOpts` blob (from `gpc gui`) or the legacy
  # bare `fcmFile`/`symbolsFile`/`entryPoint` keys.  Returns opts with an
  # absolute fcmPath field, or { fcmPath: null } if nothing is configured.
  _resolveLoadOpts: (lruConf) ->
    resolve = (p) =>
      return null unless p
      if path.isAbsolute(p) then p else path.join(@CONFIG.NSTS_TOP, p)

    if lruConf.cliOpts?.fcmPath
      # `gpc gui` passed a full options blob; fcmPath is already absolute.
      return Object.assign({}, lruConf.cliOpts, {
        fcmPath: resolve(lruConf.cliOpts.fcmPath)
        symbols: resolve(lruConf.cliOpts.symbols)
      })

    if lruConf.fcmFile
      # Legacy config shape with bare fcmFile/symbolsFile/entryPoint keys.
      return {
        fcmPath: resolve(lruConf.fcmFile)
        symbols: resolve(lruConf.symbolsFile)
        start: lruConf.entryPoint?.toString(16)
      }

    return { fcmPath: null }

  # --- Editor lookups via the dock-root (editors live in shadow DOM, so a
  # plain document.querySelector no longer finds them) ---
  _dock: () -> @dockRoot
  _editorsOf: (id) -> @dockRoot?.editorsOf(id) ? []
  _firstOf: (id) -> @_editorsOf(id)[0]

  _terminal: () -> @_firstOf('terminal')
  _breakpointLists: () -> @_editorsOf('breakpoints')
  _disasms: () -> @_editorsOf('disasm')
  _registersAll: () -> @_editorsOf('registers')

  # The editor registry handed to <dock-root>.  Each entry knows how to
  # create its custom element; the dock instantiates/destroys them as panes
  # and tabs are added/removed, and calls back into wireEditor() on mount.
  _editorRegistry: () ->
    mk = (tag) -> () -> document.createElement(tag)
    [
      { id: 'disasm',      title: 'Disassembly', create: mk('gpc-disasm') }
      { id: 'memory',      title: 'Memory',      create: mk('gpc-memory') }
      { id: 'registers',   title: 'Registers',   create: mk('gpc-regview') }
      { id: 'instr',       title: 'Instruction', create: mk('gpc-instr') }
      { id: 'watch',       title: 'Watch',       create: mk('gpc-watch') }
      { id: 'breakpoints', title: 'Breakpoints', create: mk('gpc-breakpoints') }
      { id: 'sections',    title: 'Sections',    create: mk('gpc-sections') }
      { id: 'labels',      title: 'Labels',      create: mk('gpc-labels') }
      { id: 'terminal',    title: 'Terminal', singleton: true, create: mk('gpc-terminal') }
    ]

  # Default layout used when nothing is persisted.  A binary tree of split
  # nodes (h = left|right, v = top|bottom; `size` = px of the SECOND child)
  # and leaf nodes (tabbed panes).
  _defaultLayout: () ->
    n = 0
    leaf = (editorIds...) ->
      n += 1
      { type: 'leaf', id: "L#{n}", active: 0,
        tabs: ({ iid: "DE#{n}_#{i}", editorId: e } for e, i in editorIds) }
    split = (dir, size, a, b) ->
      n += 1
      { type: 'split', id: "S#{n}", dir, size, a, b }

    rightCol = split('h', 230, leaf('registers', 'instr'), leaf('watch', 'breakpoints'))
    topRow   = split('h', 470, leaf('disasm'), rightCol)
    bottomRow = split('h', 320, leaf('memory'), leaf('sections', 'labels'))
    mainArea = split('v', 230, topRow, bottomRow)
    root = split('v', 150, mainArea, leaf('terminal'))
    { root, floats: [] }

  # Wire a freshly-created editor element to the live simulator objects.
  # Called by <dock-root> for every instance (startup restore, add-editor,
  # float) — never assume a single instance of any editor type.
  wireEditor: (el) ->
    return unless el
    switch el.tagName?.toLowerCase()
      when 'gpc-disasm'
        el.cpu = @cpu; el.sym = @sym; el.halUCP = @halUCP; el.breakpoints = @breakpoints
      when 'gpc-memory'
        el.cpu = @cpu; el.sym = @sym
        el.selectedSection = @selectedSection
        el.watchAddresses = @watchAddresses
      when 'gpc-sections'
        el.sym = @sym; el.selectedSection = @selectedSection
      when 'gpc-labels'
        el.sym = @sym; el.refresh?()
      when 'gpc-watch'
        el.cpu = @cpu; el.sym = @sym
      when 'gpc-breakpoints'
        el.cpu = @cpu; el.breakpoints = @breakpoints
      when 'gpc-instr'
        el.cpu = @cpu
      when 'gpc-regview'
        el.cpu = @cpu
        el.editable = true
    el.refresh?()

  start: () ->
    console.log("DebugGUI Start")
    console.log("DebugGUI CONFIG:", JSON.stringify(@CONFIG, null, 2))

    # Get FCM/symbols from config or use defaults
    # Note: @CONFIG is already the gpc1 LRU config (passed from startup.civet)
    lruConf = @CONFIG.config or {}
    opts = @_resolveLoadOpts(lruConf)
    if opts.fcmPath?
      console.log("DebugGUI load:", opts)
      { byteCount, entryPoint } = @configureFromOpts(opts.fcmPath, opts)
      console.log("DebugGUI loaded #{byteCount} bytes, entry=0x#{(entryPoint ? 0).toString(16)}")

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
      mem.selectedSection = @selectedSection for mem in @_editorsOf('memory')
      @updateDisplay()

    # Listen for label selection from <gpc-labels>: jump every disasm view there
    document.addEventListener 'label-selected', (e) =>
      addr = e.detail.address
      if addr?
        d.gotoAddr(addr) for d in @_disasms()

    # A register/PSW/NIA value was edited in a registers pane: re-sync all
    # panes (e.g. editing NIA should move the disassembly view).
    document.addEventListener 'register-edited', (e) =>
      @updateDisplay()

    # Listen for watch selection
    document.addEventListener 'watch-selected', (e) =>
      @selectedWatch = e.detail.name
      @watchAddresses = e.detail.addresses
      @updateDisplay()

    @setupKeyboard()
    # Poll until React has committed the <dock-root> element, then hand it the
    # editor registry + layout.  Setting `.host` makes the dock instantiate
    # every persisted editor and call wireEditor() on each.
    waitForDom = () =>
      dockEl = document.querySelector('dock-root')
      if dockEl
        @dockRoot = dockEl
        dockEl.host = {
          editors: @_editorRegistry()
          onMount: (el) => @wireEditor(el)
          defaultLayout: () => @_defaultLayout()
          storageKey: 'gpc-dock-layout'
        }
        # Initial display (twice — once now, once after layout settles)
        @updateDisplay()
        setTimeout(() =>
          @updateDisplay()
        , 100)
        window.addEventListener('resize', () => @updateDisplay())
      else
        # setTimeout (not requestAnimationFrame): rAF is paused entirely when
        # the window is occluded/backgrounded, which would stall startup.
        setTimeout(waitForDom, 16)
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
              d.frameNIA() for d in @_disasms()

  reset: () ->
    super()

    # Clear register change tracking on every registers view
    r.resetTracking?() for r in @_registersAll()

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
    # Refresh every live editor instance.  Memory/sections need their
    # selection props refreshed first.
    for el in (@dockRoot?.allEditors() ? [])
      switch el.tagName?.toLowerCase()
        when 'gpc-memory'
          el.watchAddresses = @watchAddresses
          el.selectedSection = @selectedSection
        when 'gpc-sections'
          el.selectedSection = @selectedSection
      el.refresh?()

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
    # The editor panes are managed entirely by <dock-root> (see start(),
    # which hands it the editor registry + saved/default layout once React
    # has committed this tree).

    mainStyle = {
      display: 'flex'
      flexDirection: 'column'
      height: '100%'
      backgroundColor: '#111'
      color: '#ddd'
      fontFamily: "'Consolas for Powerline', 'Consolas', monospace"
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
        <dock-root id="gpc-dock-root" style={{flex: '1', overflow: 'hidden'}}></dock-root>
      </div>
    </cde-window>

start = (CONFIG) ->
  gpc = new DebugGUI(CONFIG)
  return gpc

export default { start }
