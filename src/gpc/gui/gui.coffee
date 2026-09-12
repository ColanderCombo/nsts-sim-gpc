# DebugGUI: the debugger's front end
#
# The machine runs in a `gpc dbg-serve` process.  This window sends
# commands, listens for events, and draws a mirror of the session
# (gpc/gui/guimirror) that answers every accessor the panes were written
# against.  The session runs at full speed in that process and the window
# redraws from whatever the last snapshot carried, at whatever rate it can
# manage; neither waits for the other.
#
# Local to the window: the symbol table (static, and every pane wants it
# synchronously), the dock layout, the breakpoint list in localStorage, and
# which section or watch is selected.

fs = require 'fs'
path = require 'path'
import React from 'react'
import {SymbolTable} from 'gpc/dbg/sym/symbolTable'
import {DebugClient, resolveEndpoint, describeEndpoint} from 'gpc/dbg/dbgclient'
import {GUIMirror} from 'gpc/gui/guimirror'
import 'cde/cde-window'
import 'cde/toolbar'
import 'cde/bit-field'
import 'cde/split-pane'
import 'cde/dock'
import 'gpc/gui/widgets/gpc-register'
import 'gpc/gui/widgets/gpc-breakpoints'
import 'gpc/gui/widgets/gpc-disasm'
import 'gpc/gui/widgets/gpc-instr'
import 'gpc/gui/widgets/gpc-regview'
import 'gpc/gui/widgets/gpc-watch'
import 'gpc/gui/widgets/gpc-memory'
import 'gpc/gui/widgets/gpc-sections'
import 'gpc/gui/widgets/gpc-labels'
import 'gpc/gui/widgets/gpc-interrupts'
import 'gpc/gui/widgets/gpc-iop'
import 'gpc/gui/widgets/gpc-terminal'

# Speed multipliers offered by the toolbar's real-time selector.  A factor
# the CLI asked for that isn't in this list is added to the menu at startup.
RT_FACTORS = [0.1, 0.25, 0.5, 1, 2, 5, 10]

# What a refresh asks the session for.  Everything, in one round trip: a
# pane's redraw is synchronous and cannot wait on a second one.
SNAP_WANT = ['regs', 'ints', 'intlog', 'iop', 'breakpoints', 'halucp']

# The most consecutive fetch-and-draw passes one refresh may take.  A draw
# that reads memory the snapshot did not carry needs one more pass; two is
# the cost of the view having moved, and the bound is what stops a pane
# whose reads never settle from spinning.
MAX_PASSES = 2


export class DebugGUI
  constructor: (@CONFIG) ->
    @ipcRenderer = require('electron').ipcRenderer
    if not @ipcRenderer
      throw new Error("DebugGUI: require('electron').ipcRenderer failed!")

    @client = null
    @mirror = null
    @caps = null
    @sym = new SymbolTable()
    @fcmName = null

    # Session state, as the last snapshot or event reported it.
    @running = false
    @stepCount = 0
    @statusNote = null
    @speedRatio = null
    @realTime = false
    @rtFactor = 1.0
    @idling = false
    @waitingForInput = false
    @stopReason = 'entry'
    @intHeld = false
    @waitState = false
    @breakOnInterrupt = false
    @holdInterrupt = false

    # GUI-local
    @breakOnInput = false
    @selectedSection = null
    @selectedWatch = null
    @watchAddresses = null

    @_inflight = false
    @_again = false
    @_connected = false
    @_warnedTruncated = false

  #
  # Where the session is
  #
  # `gpc gui` starts one and passes its endpoint; `--attach` passes the one
  # to join.  With neither -- a window opened by hand -- fall back on the
  # session file, the same way `gpc dbg-client` does.
  _endpoint: () ->
    o = @CONFIG.config?.cliOpts ? {}
    return o.endpoint if o.endpoint?
    resolveEndpoint(o)

  start: () ->
    ep = @_endpoint()
    console.log("DebugGUI: connecting to #{describeEndpoint(ep)}")
    @client = new DebugClient(ep)
    @_wireEvents()
    @client.connect().then((welcome) =>
      @_connected = true
      console.log("DebugGUI: connected, protocol #{welcome.protocol}")
      @client.send('capabilities')
    ).then((caps) =>
      @_openSession(caps)
    ).catch (e) =>
      console.error("DebugGUI: #{e.message}", e)
      @notify("no session at #{describeEndpoint(ep)}: #{e.message}")
      @updateToolbar()
    return

  # The session is up: take its symbols, size the mirror to its machine,
  # hand back the breakpoints this image had last time, and build the dock.
  _openSession: (caps) ->
    @caps = caps
    @fcmName = caps.fcmName ? null
    if caps.symbols?.path
      try
        @sym.load(caps.symbols.path)
        console.log("DebugGUI: symbols from #{caps.symbols.path}")
      catch e
        console.warn("DebugGUI: cannot read #{caps.symbols.path}: #{e.message}")
    m = caps.machine ? {}
    totalHW = ((m.cpuWords ? 256 * 1024) + (m.iopWords ? 0)) * 2
    @mirror = new GUIMirror({
      totalHW: totalHW
      write: (cmd, args) => @client.post(cmd, args)
    })
    @_restoreBreakpoints()
    @_wireDOM()
    @refresh()
    return

  #
  # Session events
  #
  _wireEvents: () ->
    @client.on 'stopped', (b) =>
      @running = false
      @_takeStop(b)
      @refresh()
    @client.on 'continued', (b) =>
      @running = true
      @statusNote = null
      @updateToolbar()
    # One per chunk of a run: the session's refresh tick.
    @client.on 'running', (b) =>
      @running = true
      @stepCount = b.steps
      @speedRatio = b.speedRatio
      @refresh()
    @client.on 'output', (b) =>
      @_terminal()?.appendText(b.text)
      process.stderr.write(b.text) if b.category == 'stderr'
    @client.on 'input', (b) =>
      @waitingForInput = true
      @_terminal()?.activateInput()
      @updateToolbar()
    @client.on 'closed', =>
      @running = false
      @notify('the session closed')
      @updateToolbar()
    return

  _takeStop: (b) ->
    return unless b?
    @stopReason = b.reason
    @statusNote = b.description ? null
    @stepCount = b.steps ? @stepCount
    @waitState = !!b.waitState
    @waitingForInput = !!b.waitingForInput
    @intHeld = b.heldInterrupt?
    @speedRatio = null
    return

  #
  # Refresh
  #
  # One pass is: ask for the memory the last draw read, fill the mirror,
  # draw.  A draw that reached past what was asked for leaves the mirror
  # stale, and one more pass settles it.  Requests do not queue -- a run
  # emits a progress event per chunk and the window redraws at whatever rate
  # it can, dropping the ones in between.
  #
  refresh: () ->
    return unless @mirror? and @client?.connected
    if @_inflight
      @_again = true
      return
    @_pass(MAX_PASSES)
    return

  _pass: (left) ->
    @_inflight = true
    req = {
      windows: @mirror.windows()
      want: SNAP_WANT
      intlogcount: 40
    }
    dis = @mirror.iopDisasmWanted()
    req.iopdisasm = dis if dis.length > 0
    # A refresh that could not carry everything the panes read leaves some
    # of them showing values that are quietly out of date.  Reported once.
    if @mirror.truncated > 0 and not @_warnedTruncated
      @_warnedTruncated = true
      @notify("#{@mirror.truncated} halfwords past the refresh ceiling: " +
              "some panes will show stale values")
    @client.send('guisnap', req).then((snap) =>
      @_inflight = false
      @mirror.apply(snap)
      @_takeSnap(snap)
      @_draw()
      if @mirror.stale() and left > 1
        @_pass(left - 1)
      else if @_again
        @_again = false
        @_pass(MAX_PASSES)
    ).catch (e) =>
      @_inflight = false
      console.warn("DebugGUI: guisnap failed: #{e.message}")

  _takeSnap: (snap) ->
    @running = !!snap.running
    @stepCount = snap.steps
    @speedRatio = snap.speedRatio
    @realTime = !!snap.realTime
    @rtFactor = snap.rtFactor ? @rtFactor
    @idling = !!snap.idling
    @statusNote = snap.statusNote ? @statusNote
    @_takeStop(snap.status) if not @running
    @waitState = !!snap.status?.waitState
    @waitingForInput = !!snap.halucp?.waitingForInput
    @intHeld = snap.status?.heldInterrupt?
    if snap.ints?
      @breakOnInterrupt = !!snap.ints.breakOnInterrupt
      @holdInterrupt = !!snap.ints.hold
    return

  # Draw every live pane, with the mirror recording what they read.
  _draw: () ->
    @mirror.beginTrack()
    try
      for el in (@dockRoot?.allEditors() ? [])
        switch el.tagName?.toLowerCase()
          when 'gpc-memory'
            el.watchAddresses = @watchAddresses
            el.selectedSection = @selectedSection
          when 'gpc-sections'
            el.selectedSection = @selectedSection
        el.refresh?()
    finally
      @mirror.endTrack()
    @updateToolbar()
    return

  # The old harness's name for a redraw; the panes and the components call
  # it, so it stays.
  updateDisplay: () -> @refresh()

  notify: (msg) ->
    @statusNote = msg
    console.log("DebugGUI: #{msg}")
    return

  #
  # Execution
  #
  # These are all fire-and-forget: an execution command replies only when
  # the machine stops, and the `stopped` event is what drives the redraw.
  #
  step: () -> @_exec('step', { count: 1 })
  stepOver: () -> @_exec('next')
  run: () -> @_exec('continue')
  runTo: (addr) -> @_exec('until', { addr })
  stop: () -> @_exec('pause')
  reset: () ->
    @_resetPanes()
    @_exec('reset')
  systemReset: () -> @_exec('sysreset')

  _exec: (cmd, args = {}) ->
    return unless @client?.connected
    @statusNote = null
    @client.post(cmd, args)
    return

  _resetPanes: () ->
    r.resetTracking?() for r in @_registersAll()
    term = @_terminal()
    if term
      term.clear()
      term.resetInput()
    return

  #
  # Controls
  #
  setRealTime: (enabled) ->
    @realTime = !!enabled
    @client?.post('realtime', { state: @realTime })
    @updateToolbar()

  setRTFactor: (f) ->
    f = parseFloat(f)
    return unless isFinite(f) and f > 0
    @rtFactor = f
    @client?.post('realtime', { factor: String(f) })
    @updateToolbar()

  setBreakOnInterrupt: (enabled) ->
    @breakOnInterrupt = !!enabled
    @client?.post('intbreak', { state: @breakOnInterrupt })
    @updateToolbar()

  setHoldInterrupt: (enabled) ->
    @holdInterrupt = !!enabled
    @client?.post('inthold', { state: @holdInterrupt })
    @updateToolbar()

  raiseInterrupt: (key) -> @_exec('intraise', { key })
  clearInterrupt: (key) -> @_exec('intclear', { key })
  toggleInterruptMask: (maskBit) -> @_exec('intmask', { bit: maskBit })
  loadTimer: (n, value) -> @_exec('timerload', { n, value })
  clearInterruptLog: () -> @_exec('intlog', { count: 1, clear: true })

  #
  # Breakpoints
  #
  # The session owns them; localStorage keeps them across runs of the app,
  # keyed by image.
  #
  toggleBreakpoint: (addr) ->
    bp = @mirror?.breakpoints.get(addr)
    if bp?
      cmd = if bp.enabled then 'bdisable' else 'benable'
      @_exec(cmd, { addr })
    else
      @_exec('break', { addr })
    @_saveBreakpointsAfter()

  # `bclear` takes a string, because `*` clears them all -- so the address
  # goes over 0x-prefixed.  A bare decimal would be read as hex.
  deleteBreakpoint: (addr) ->
    @_exec('bclear', { addr: "0x#{addr.toString(16)}" })
    @_saveBreakpointsAfter()

  enableBreakpoint: (addr) ->
    @_exec('benable', { addr })
    @_saveBreakpointsAfter()

  disableBreakpoint: (addr) ->
    @_exec('bdisable', { addr })
    @_saveBreakpointsAfter()

  addBreakpoint: (addr) ->
    @_exec('break', { addr })
    @_saveBreakpointsAfter()

  # The session holds the list, so it is read back after every change.
  _saveBreakpointsAfter: () ->
    return unless @client?.connected and @fcmName
    @client.send('breakpoints').then((r) =>
      window.localStorage?.setItem("gpc-bp:#{@fcmName}",
        JSON.stringify({ addr: b.addr, enabled: b.enabled } for b in r.breakpoints))
      @refresh()
    ).catch (e) -> null
    return

  _restoreBreakpoints: () ->
    return unless @fcmName
    json = window.localStorage?.getItem("gpc-bp:#{@fcmName}")
    return unless json
    try
      saved = JSON.parse(json)
    catch e
      return
    return if saved.length == 0
    @client.post('setbreakpoints', { addrs: (b.addr for b in saved) })
    for b in saved when b.enabled == false
      @client.post('bdisable', { addr: b.addr })
    return

  #
  # Editor lookups via the dock-root
  #
  # Editors live in shadow DOM, where document.querySelector cannot reach
  # them.
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
      { id: 'interrupts',  title: 'Interrupts',  create: mk('gpc-interrupts') }
      { id: 'iop',         title: 'IOP',         create: mk('gpc-iop') }
      { id: 'terminal',    title: 'Terminal', singleton: true, create: mk('gpc-terminal') }
    ]

  # Default layout used when nothing is persisted.  A binary tree of split
  # nodes (h = left|right, v = top|bottom; `size` = px of the second child)
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

    rightCol = split('h', 230, leaf('registers', 'instr'), leaf('watch', 'breakpoints', 'interrupts', 'iop'))
    topRow   = split('h', 470, leaf('disasm'), rightCol)
    bottomRow = split('h', 320, leaf('memory'), leaf('sections', 'labels'))
    mainArea = split('v', 230, topRow, bottomRow)
    root = split('v', 150, mainArea, leaf('terminal'))
    { root, floats: [] }

  # Wire a freshly-created editor element to the mirror.  Called by
  # <dock-root> for every instance (startup restore, add-editor, float):
  # never assume a single instance of any editor type.
  wireEditor: (el) ->
    return unless el and @mirror?
    cpu = @mirror.cpu
    switch el.tagName?.toLowerCase()
      when 'gpc-disasm'
        el.cpu = cpu; el.sym = @sym; el.halUCP = @mirror.halUCP
        el.breakpoints = @mirror.breakpoints
      when 'gpc-memory'
        el.cpu = cpu; el.sym = @sym
        el.selectedSection = @selectedSection
        el.watchAddresses = @watchAddresses
      when 'gpc-sections'
        el.sym = @sym; el.selectedSection = @selectedSection
      when 'gpc-labels'
        el.sym = @sym; el.refresh?()
      when 'gpc-watch'
        el.cpu = cpu; el.sym = @sym
      when 'gpc-breakpoints'
        el.cpu = cpu; el.breakpoints = @mirror.breakpoints
      when 'gpc-instr'
        el.cpu = cpu
      when 'gpc-interrupts'
        el.cpu = cpu; el.iop = @mirror.iop; el.harness = @
      when 'gpc-iop'
        el.iop = @mirror.iop
      when 'gpc-regview'
        el.cpu = cpu
        el.editable = true
    el.refresh?()

  #
  # DOM
  #
  _wireDOM: () ->
    # Listen for input submitted from <gpc-terminal>
    document.addEventListener 'terminal-input', (e) =>
      @waitingForInput = false
      @client?.post('input', { text: e.detail.text, noresume: @breakOnInput })

    document.addEventListener 'break-on-input-changed', (e) =>
      @breakOnInput = e.detail.value

    document.addEventListener 'breakpoint-toggle', (e) =>
      @toggleBreakpoint(e.detail.addr)
    document.addEventListener 'breakpoint-menu', (e) =>
      @showBreakpointMenu({ clientX: e.detail.x, clientY: e.detail.y }, e.detail.addr)

    document.addEventListener 'section-selected', (e) =>
      @selectedSection = e.detail.name
      mem.selectedSection = @selectedSection for mem in @_editorsOf('memory')
      @refresh()

    # Jump every disasm view to the label
    document.addEventListener 'label-selected', (e) =>
      addr = e.detail.address
      if addr?
        d.gotoAddr(addr) for d in @_disasms()
        @refresh()

    # A register/PSW/NIA value was edited in a registers pane.  The mirror
    # has already written it through to the session; re-sync every pane.
    document.addEventListener 'register-edited', (e) =>
      @refresh()

    document.addEventListener 'interrupt-raise', (e) => @raiseInterrupt(e.detail.key)
    document.addEventListener 'interrupt-clear', (e) => @clearInterrupt(e.detail.key)
    document.addEventListener 'interrupt-mask-toggle', (e) => @toggleInterruptMask(e.detail.maskBit)
    document.addEventListener 'interrupt-log-clear', (e) => @clearInterruptLog()
    document.addEventListener 'break-on-interrupt-changed', (e) => @setBreakOnInterrupt(e.detail.value)
    document.addEventListener 'hold-interrupt-changed', (e) => @setHoldInterrupt(e.detail.value)
    document.addEventListener 'timer-load', (e) => @loadTimer(e.detail.n, e.detail.value)
    document.addEventListener 'system-reset', (e) => @systemReset()

    document.addEventListener 'watch-selected', (e) =>
      @selectedWatch = e.detail.name
      @watchAddresses = e.detail.addresses
      @refresh()

    @setupKeyboard()

    # Poll until React has committed the <dock-root> element, then hand it
    # the editor registry + layout.  Setting `.host` makes the dock
    # instantiate every persisted editor and call wireEditor() on each.
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
        @refresh()
        setTimeout((=> @refresh()), 100)
        window.addEventListener('resize', () => @refresh())
      else
        # setTimeout (not requestAnimationFrame): rAF is paused entirely when
        # the window is occluded/backgrounded, which would stall startup.
        setTimeout(waitForDom, 16)
    requestAnimationFrame(waitForDom)
    return

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
              @refresh()

  # Closing the window leaves the session running: it is a separate process
  # and another client -- `gpc dbg-client`, or a second window -- may be
  # using it.  `gpc gui` shuts down the one it started.
  quit: () ->
    @client?.close()
    @ipcRenderer.send('window-close')

  showBreakpointMenu: (e, addr) ->
    # Remove any existing context menu
    old = document.getElementById('gpc-bp-context-menu')
    old?.remove()

    bp = @mirror?.breakpoints.get(addr)
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
      menu.appendChild(makeItem("Add breakpoint #{addrStr}", => @addBreakpoint(addr)))

    document.body.appendChild(menu)
    # Close on any click elsewhere
    closeHandler = (ev) ->
      if not menu.contains(ev.target)
        menu.remove()
        document.removeEventListener('mousedown', closeHandler, true)
    setTimeout(( -> document.addEventListener('mousedown', closeHandler, true)), 0)

  #
  # Toolbar
  #
  simTimeSec: () -> @mirror?.snap?.simTimeSec ? 0

  _syncRTControls: () ->
    chk = document.getElementById('gpc-rt-check')
    chk.checked = @realTime if chk? and chk.checked != @realTime
    sel = document.getElementById('gpc-rt-factor')
    if sel?
      want = String(@rtFactor)
      if not (o for o in sel.options when o.value == want).length
        opt = document.createElement('option')
        opt.value = want
        opt.textContent = "#{want}x"
        sel.appendChild(opt)
      sel.value = want if sel.value != want
      sel.disabled = not @realTime

  updateToolbar: () ->
    nia = @mirror?.cpu.psw.getNIA() ? 0
    niaEl = document.getElementById('gpc-nia-display')
    if niaEl
      niaEl.textContent = "NIA: #{nia.toString(16).padStart(5, '0')}"
    stepsEl = document.getElementById('gpc-steps-display')
    if stepsEl
      stepsEl.textContent = "Steps: #{@stepCount}"
    @_syncRTControls()
    simEl = document.getElementById('gpc-simtime-display')
    if simEl
      txt = "Sim: #{@simTimeSec().toFixed(3)}s"
      txt += " (#{@speedRatio.toFixed(2)}x)" if @running and @speedRatio?
      simEl.textContent = txt
    statusEl = document.getElementById('gpc-status-display')
    if statusEl
      if not @_connected
        statusEl.textContent = "NO SESSION"
      else if @waitingForInput
        statusEl.textContent = "INPUT WAIT"
      else if @intHeld
        statusEl.textContent = "INT HELD"
      else if @waitState
        statusEl.textContent = if @idling then "WAIT (idling)" else "WAIT"
      else if @running
        statusEl.textContent = if @realTime then "RUNNING (real-time)" else "RUNNING"
      else
        statusEl.textContent = "STOPPED"
      if @statusNote
        statusEl.textContent += " — #{@statusNote}"
        statusEl.style.color = '#f80'
      else
        statusEl.style.color = ''
      statusEl.title = @statusNote ? ''

  _uiGPCRegister: (id, bits, base, name, slice=-1, sliceend=-1) ->
    <gpc-register id={id} key={id} bits={bits} base={base} name={name} slice={slice} sliceend={sliceend} value={0}/>

  initWindow: () ->
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
          <label id="gpc-rt-label" style={{marginLeft: '12px', display: 'inline-flex', alignItems: 'center', gap: '3px'}}
                 title="Pace execution at AP-101S speed, and keep simulated time (and the interval timers) running through the wait state">
            <input type="checkbox" id="gpc-rt-check" onChange={(e) => this.setRealTime(e.target.checked)}/>
            Real-time
          </label>
          <select id="gpc-rt-factor" title="Real-time speed multiplier"
                  onChange={(e) => this.setRTFactor(e.target.value)}>
            {RT_FACTORS.map((f) => <option key={f} value={f}>{f}x</option>)}
          </select>
          <span id="gpc-status-display" slot="status">STOPPED</span>
          <span id="gpc-simtime-display" slot="status">Sim: 0.000s</span>
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
